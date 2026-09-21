import Foundation
import FoundationModels

/// One session, kept alive across questions.
///
/// Run as a command, fmtool is one process per question: a new session, a new
/// mind, nothing remembered. That is right for a shell and wrong for a
/// conversation — ask "where is 新宿?" and then "and the next one?", and the
/// second question has nothing to be "next" to.
///
/// `--serve` keeps the process (and its session) alive and answers questions
/// off stdin, one JSON object per line:
///
///     {"id": 1, "prompt": "新宿はどこ？"}   → {"id":1,"text":"…","tool":"mywant_cli"}
///     {"id": 2, "reset": true}               → {"id":2,"text":"(session reset)"}
///
/// The transcript is the memory, and it is finite: this model has 8k tokens for
/// everything it has ever been told, and a few turns of tool output fill it.
/// The framework does not manage that for you — it throws when the window is
/// full — but it does hand you the conversation (`session.transcript`) and let
/// you start a session from one. So the memory is kept in the session itself
/// and trimmed there: the instructions that opened it, plus the most recent
/// turns, carried into a new session. What gets dropped is the oldest talk and
/// the tool output that came with it, which is what filled the window in the
/// first place.
///
/// Trimming happens on a schedule as well as on overflow: recovering at the
/// wall costs the asker a slow turn, and this way they rarely meet it.

/// Holds the live session and does the trimming, so the answering code never
/// has to know which session it is on.
actor SessionBox {
    private var session: LanguageModelSession
    private let tools: [any Tool]
    private let instructions: String
    private var turns = 0

    /// How many entries of the old conversation are carried over. Six is about
    /// three exchanges — enough for "what were we just talking about" — and few
    /// enough that the carried transcript is not itself the thing that fills
    /// the next window.
    private static let carriedEntries = 6
    /// How many turns a session takes before it is trimmed on purpose.
    private static let turnsBeforeTrim = 6

    init(tools: [any Tool], instructions: String) {
        self.tools = tools
        self.instructions = instructions
        self.session = LanguageModelSession(tools: tools, instructions: instructions)
    }

    func current() -> LanguageModelSession { session }

    /// One turn finished. Trims when this session has had enough of them, and
    /// reports whether it did.
    func finishedTurn() -> Bool {
        turns += 1
        guard turns >= Self.turnsBeforeTrim else { return false }
        trim()
        return true
    }

    /// Carry the recent conversation into a new session and drop the rest.
    ///
    /// The entries come from the session's own transcript, so what is carried
    /// is what was actually said — prompts, answers, and the tool calls among
    /// them — rather than a second copy of the conversation kept alongside.
    func trim() {
        let entries = Array(session.transcript)
        guard entries.count > Self.carriedEntries + 1 else { return }

        // A transcript is not a list of lines, it is a sequence of turns: a
        // prompt, what the model did about it, what it answered. Cut anywhere
        // else and the carried conversation starts mid-turn — a tool's output
        // with nothing that asked for it — and the model cannot read it at all:
        // "Unable to tokenize prompt", on every question after the first trim.
        //
        // So the cut is made at a question. Take the recent entries, then walk
        // forward to the first prompt and start there.
        var recent = Array(entries.dropFirst().suffix(Self.carriedEntries))
        while let first = recent.first, !isPrompt(first) {
            recent.removeFirst()
        }
        guard !recent.isEmpty else { return }

        // The instructions the session opened with: a session built from a
        // transcript takes them from it, so they are carried whatever else goes.
        var kept: [Transcript.Entry] = []
        if let opening = entries.first { kept.append(opening) }
        kept.append(contentsOf: recent)
        session = LanguageModelSession(tools: tools, transcript: Transcript(entries: kept))
        turns = 0
    }

    private func isPrompt(_ entry: Transcript.Entry) -> Bool {
        if case .prompt = entry { return true }
        return false
    }

    /// Start again with nothing remembered at all — for a caller asking
    /// outright to forget.
    func reset() {
        session = LanguageModelSession(tools: tools, instructions: instructions)
        turns = 0
    }
}

private struct ServeRequest: Decodable {
    let id: Int?
    let prompt: String?
    let reset: Bool?
    /// Answer with the model alone: no tools, no memory of this conversation.
    ///
    /// The caller that asks for this is not chatting — it is MyWant working out
    /// which of its own commands carry out a request, and it has the command
    /// list, the results so far and the rules in the prompt it just wrote. Sent
    /// through the ordinary session, that planning question met a model with
    /// tools of its own: it went and ran searches, answered "the search results
    /// did not provide the required information", and planned nothing. What is
    /// wanted here is the one thing this model has that the caller does not —
    /// language — and none of its initiative.
    let plain: Bool?
}

/// What a plain session is told: answer the question as asked, in the form
/// asked, and nothing else.
private let plainInstructions = """
    You turn a request into exactly the line you are asked for.
    Follow the answer format in the prompt exactly. Add no explanation, no     greeting and no commentary. If the prompt offers a list to choose from,     choose only from that list.
    """

private func writeLine(_ object: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: object),
          var line = String(data: data, encoding: .utf8) else { return }
    line += "\n"
    FileHandle.standardOutput.write(line.data(using: .utf8)!)
}

/// Answer on the kept session, trimming and trying again if the window is full.
func servedRespond(prompt: String, box: SessionBox, tools: [any LocalTool], tracker: CallTracker) async -> (text: String, tool: String?, trimmed: Bool) {
    for attempt in 0..<2 {
        let session = await box.current()
        do {
            let response = try await session.respond(to: prompt)
            if await tracker.count > 0 {
                return (response.content, await tracker.lastToolName, attempt > 0)
            }
            // Nothing fired on its own: let the model plan the steps, on this
            // same session so the plan and what it found stay part of the
            // conversation.
            let planned = try await planRespond(session: session, prompt: prompt, tools: tools)
            return (planned.finalText, planned.toolUsed, attempt > 0)
        } catch {
            printErr("[serve] \(error.localizedDescription) — trimming the conversation")
            await box.trim()
        }
    }
    return ("答えられませんでした（会話が長すぎたので短くしました。もう一度どうぞ）", nil, true)
}

/// Read questions off stdin until it closes, answering each on the kept session.
func serve(makeTools: @Sendable (CallTracker) -> (localTools: [any LocalTool], tools: [any Tool]), instructions: String, said: CurrentRequest? = nil, goals: GoalBox? = nil) async {
    let tracker = CallTracker()
    let (localTools, tools) = makeTools(tracker)
    let box = SessionBox(tools: tools, instructions: instructions)
    // From here on, commands are the caller's to run: this asks and relays.
    // Only in this mode — a one-shot run has nobody to ask (see Broker).
    await Broker.shared.listen()
    printErr("[serve] ready")

    while let line = readLine(strippingNewline: true) {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedLine.isEmpty { continue }
        guard let data = trimmedLine.data(using: .utf8),
              let request = try? JSONDecoder().decode(ServeRequest.self, from: data) else {
            writeLine(["error": "bad request: \(trimmedLine.prefix(200))"])
            continue
        }
        let id = request.id ?? 0

        if request.reset == true {
            await box.reset()
            writeLine(["id": id, "text": "(session reset)"])
            continue
        }
        guard let prompt = request.prompt, !prompt.isEmpty else {
            writeLine(["id": id, "error": "prompt is required"])
            continue
        }

        if request.plain == true {
            // A session of its own, made and dropped: no tools to reach for and
            // no transcript to fill, so the answer is about this prompt only.
            let session = LanguageModelSession(instructions: plainInstructions)
            do {
                let response = try await session.respond(to: prompt)
                writeLine(["id": id, "text": response.content, "calls": 0])
            } catch {
                writeLine(["id": id, "error": "\(error.localizedDescription)"])
            }
            continue
        }


        // What was said, kept for the one command that takes a request
        // verbatim (see the `do` handback in MyWantCLI). Whether it was a yes
        // to something waiting is not read here at all any more: that is the
        // caller's, which is the only side that knows what was offered.
        await said?.note(prompt: prompt)

        let before = await tracker.count
        let answer = await servedRespond(prompt: prompt, box: box, tools: localTools, tracker: tracker)
        let calls = await tracker.count - before
        let trimmedAfter = await box.finishedTurn()
        var reply: [String: Any] = ["id": id, "text": answer.text, "calls": calls]
        if let tool = answer.tool { reply["tool"] = tool }
        // A request handed back rather than answered: the caller runs it (see
        // GoalBox). Its own field, because what comes back from that work is
        // the real answer to this turn, and the text above is only the agent
        // saying it is on it.
        if let goal = await goals?.take(), !goal.isEmpty {
            reply["goal"] = goal
        }
        if answer.trimmed || trimmedAfter { reply["trimmed"] = true }
        writeLine(reply)
    }
    printErr("[serve] stdin closed, exiting")
}
