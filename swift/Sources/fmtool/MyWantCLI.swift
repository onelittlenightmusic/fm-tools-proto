import Foundation
import FoundationModels

/// The whole MyWant CLI as one tool, described by the CLI itself.
///
/// The tools beside this one name their actions in Swift: a list of strings
/// compiled into the binary, which is a copy of the CLI kept by hand. Every such
/// copy goes stale — the CLI grew things, worlds, state and logs while this
/// agent could still only ask about wants and agents.
///
/// So the command list is not written here. At startup `mywant commands --json`
/// is asked what this CLI can do, and the answer becomes the tool's own schema:
/// the model picks from the commands the binary actually has. A command added to
/// the CLI is available the next time fmtool starts, with nothing to change here.
///
/// What is offered is decided by the CLI too. Every command says what it costs
/// if it was the wrong one — "read", "change" or "destroy" — and whether it is
/// about what is drawn on the canvas at all. Reads are offered whatever they
/// are about; writing is offered for the board and nowhere else, because this
/// same CLI installs plugins and rewrites config, and a small model asked to
/// move a tile will sometimes pick one of those.
///
/// Destroying is offered too, and that is new. It used to be a separate tool
/// here that refused to run until the person had said yes — a gate written in
/// Swift, beside a second one written in Go, disagreeing about which words are
/// a yes. Now nothing is run here at all: every command goes to the caller,
/// which knows the risk, asks the person when there is something to ask about,
/// and never lets this model answer for them. See Broker.swift.
struct MyWantCommand: Decodable {
    let path: String
    let short: String?
    let use: String?
    let readOnly: Bool
    let risk: String?
    /// Whether it concerns what is drawn — the tiles, the things, where they
    /// stand — as opposed to the server behind them. The CLI labels this
    /// itself; a copy of that judgement lived here as a list of group names
    /// and went stale the day `gui tile set` became board work.
    let canvas: Bool?
}

enum MyWantCLI {
    /// Where the CLI is: MYWANT_BIN, then PATH, then ~/.local/bin, which is
    /// where `make install` puts it.
    static func binaryPath() -> String? {
        let fm = FileManager.default
        if let named = ProcessInfo.processInfo.environment["MYWANT_BIN"], !named.isEmpty,
           fm.isExecutableFile(atPath: named) {
            return named
        }
        for dir in ["/opt/homebrew/bin", "/usr/local/bin"] {
            let candidate = dir + "/mywant"
            if fm.isExecutableFile(atPath: candidate) { return candidate }
        }
        let home = NSHomeDirectory() + "/.local/bin/mywant"
        if fm.isExecutableFile(atPath: home) { return home }
        return nil
    }

    /// Run the CLI and hand back what it printed.
    static func run(_ binary: String, _ args: [String], timeout: TimeInterval = 60) throws -> (out: String, err: String, status: Int32) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = args
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        try process.run()

        // Read before waiting: a command with more output than a pipe buffer
        // holds would otherwise block forever with the parent waiting on exit.
        let outData = outPipe.fileHandleForReading.readDataToEndOfFile()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(data: outData, encoding: .utf8) ?? "",
            String(data: errData, encoding: .utf8) ?? "",
            process.terminationStatus
        )
    }

    /// Everything the CLI says it can do, or nothing when there is no CLI here
    /// to ask. Plugins included: the core CLI collects them (`gui tile set` is
    /// how a tile moves, and it lives in another binary entirely).
    static func allCommands() -> [MyWantCommand] {
        guard let binary = binaryPath() else { return [] }
        guard let result = try? run(binary, ["commands", "--json"], timeout: 20),
              result.status == 0,
              let data = result.out.data(using: .utf8),
              let commands = try? JSONDecoder().decode([MyWantCommand].self, from: data)
        else { return [] }
        return commands
    }

    /// What to offer the model.
    ///
    /// Reads always. Writes — change and destroy alike — only where the CLI
    /// says the command is about the canvas, plus `do`, which is how anything
    /// gets built and is not canvas work by the CLI's own reckoning (it makes
    /// a goal; the goal does the board work). Destroying is in the same list
    /// as everything else now: the caller stops it, not this.
    ///
    /// Asked "NakanoのWeatherを作りたい" in chat, this agent ran
    /// `wants create AAA-test Weather` — the words of the request as
    /// positional arguments — which the CLI refuses, since a want is created
    /// with a type and its parameters. Working those out is a handful of small
    /// questions, and MyWant already does it: `do` takes the request and is
    /// handed straight back to the caller (see the call below), which looks up
    /// the type, fills the parameters and runs the create.
    static func offered(writes: Bool) -> [MyWantCommand] {
        let commands = allCommands()
        let risk = { (c: MyWantCommand) in c.risk ?? (c.readOnly ? "read" : "change") }
        let board = { (c: MyWantCommand) in c.canvas == true || c.path == "do" }
        return trimmed(commands.filter {
            risk($0) == "read" || (writes && board($0))
        })
    }

    /// Two kinds are left out of what the model is offered, and only out of
        // THAT — both stay in the CLI for people and scripts.
        //
        //   commands   lists what the CLI can do, which this tool's description
        //              already carries; offering it invites a call that answers
        //              nobody's question, and it did.
        //   … where    is the half of an answer its `point` sibling gives whole:
        //              the same cell, without going to show it. Offered both,
        //              the model picked `where` about half the time and the
        //              asker got coordinates and a robot standing where it was.
        //              A guide shows; anybody who wants the quiet form can run
        //              it themselves.
    static func trimmed(_ commands: [MyWantCommand]) -> [MyWantCommand] {
        let superseded = Set(commands.map(\.path).filter { $0.hasSuffix(" point") }
            .map { $0.replacingOccurrences(of: " point", with: " where") })
        return commands.filter { $0.path != "commands" && !superseded.contains($0.path) }
    }
}

/// One tool for every command the CLI offers, destroying included.
///
/// One, because two invited the model to reach for the wrong one: asked to
/// DELETE a want it once chose `wants disconnect`, which is a different tool's
/// neighbour doing a very different thing. What stops a deletion is not which
/// tool it arrived in — it is the caller, which refuses to run it until a
/// person has said yes.
struct MyWantCLITool: LocalTool {
    let name = "mywant_cli"
    let commands: [MyWantCommand]
    /// What was asked this turn, for the one command that takes a request.
    var request: CurrentRequest?
    /// Where a request to make or find something is handed back to the caller.
    var goals: GoalBox?
    /// Whether the offered list includes commands that change the board, which
    /// decides whether the description bothers to say what they are.
    var canWrite: Bool { commands.contains { ($0.risk ?? "read") == "change" } }
    /// Whether anything offered takes something away, which is worth a
    /// sentence of its own: the model has to know it may call these, and that
    /// what comes back may be a question rather than a result.
    var canDestroy: Bool { commands.contains { $0.risk == "destroy" } }
    private let binary: String
    private static let outputLimit = 4000

    init?(commands: [MyWantCommand], request: CurrentRequest? = nil, goals: GoalBox? = nil) {
        guard let binary = MyWantCLI.binaryPath(), !commands.isEmpty else { return nil }
        self.binary = binary
        self.commands = commands
        self.request = request
        self.goals = goals
    }

    var description: String {
        "THE tool for any question about MyWant: wants, things (named values), the canvas/board, worlds, "
        + "state, agents, recipes, logs, server status. Use it — never the file search — whenever MyWant, "
        + "a want, a thing or the board is mentioned. "
        + "Pick `command` from the list and give `args` everything that command needs and nothing else — "
        + "a name alone for a question about one thing (args \"新宿\", never \"新宿はどこ\"), and a name "
        + "followed by the numbers when the command places something (args \"新宿 5 0\"). Never the sentence "
        + "it was asked in. "
        // The confusions worth naming, each one seen: a question about the
        // board answered from the filesystem, and processes counted as wants.
        // What each command IS, not what order to call them in: the order is the
        // model's to work out (see Plan.swift), and procedures written here go
        // stale as fast as the CLI grows.
        + "'board' names everything on the canvas, spelled as 'point' expects. 'point' takes one name and "
        + "says where it is AND walks the robot there, so the asker can see it. "
        // The board is a graph, not a pile: this is the edge between two of its
        // tiles, and the question "what is X connected to" has one answer that
        // knows about both kinds of edge.
        + "Things and wants are CONNECTED to each other: a want reads the things it names and the fields of "
        + "other wants, and feeds its own fields on. 'relations' takes one name and lists those connections "
        + "in both directions — use it for 'what is X connected to', 'what feeds X', 'what uses X'. "
        + "A want is something on the board — 'wants list'. 'ps' is the server's own processes, not wants. "
        + "Named values are things — 'thing list'."
        // What the writing verbs ARE. The model chooses from bare command
        // paths — the descriptions the CLI carries never reach the schema — so
        // "Parasomniaを(9,-9)に移動して" met a list in which nothing said "move"
        // and picked 'point', which walked over and reported the old cell.
        // Still no procedures: which of these to call, and in what order, is
        // the model's to work out.
        + (canWrite
           ? " To MAKE something that does not exist yet — a want for a place, a tile for a thing — call "
             + "'do' with the person's own request as its one argument: args \"NakanoのWeatherを作りたい\". "
             + "It works out the type and the values and reports back; never try to build one with "
             + "'wants create' from here. "
             + "Asked to take back, revert or undo what was just done (元に戻す), call 'undo' with no args — "
             + "never work out the reverse yourself, it is recorded. "
             + "To PLACE or MOVE a thing: 'thing pin' with args \"<name> <x> <y>\"; to take it off the board: "
             + "'thing unpin'. To move a want's tile: 'gui tile set' with args \"<name> <x> <y>\". "
             + "To make a want: 'wants create' with args \"--type <type> --at <x>,<y>\". "
             + "To take back the last change: 'undo', with no args."
           : "")
        // Said plainly, because the model's instinct is to refuse on the
        // person's behalf and then report it as impossible. It is not this
        // tool's to refuse: call it, and relay what comes back.
        + (canDestroy
           ? " Asked to DELETE or REMOVE something, call the command that does it. Nothing is destroyed by "
             + "calling: if a person has to agree first, the reply says so and says what is waiting. "
             + "Tell them that, in their language, and say it is permanent — never that it failed and "
             + "never that it is impossible."
           : "")
    }

    var argsSchema: DynamicGenerationSchema {
        // The catalogue the model chooses from IS the CLI's own, read at
        // startup — see the note at the top of this file.
        let paths = commands.map(\.path)
        // Short on purpose. Every word here rides in the prompt of every
        // request, and this model has 8k tokens for the whole conversation —
        // a full catalogue with its descriptions left so little room that a
        // four-word question could overflow the window mid-turn. The paths
        // alone say most of it; `commands --json` has the rest for anyone who
        // needs it.
        let summary = commands
            .prefix(24)
            .map(\.path)
            .joined(separator: ", ")
        return DynamicGenerationSchema(
            name: "MyWantCLIArgs",
            properties: [
                .init(
                    name: "command",
                    description: "The command to run. \(summary)",
                    schema: DynamicGenerationSchema(name: "MyWantCLICommand", anyOf: paths)
                ),
                .init(
                    name: "args",
                    description: "Everything the command needs, space-separated and in order: a name, or a name then numbers. Leave empty for a plain list.",
                    schema: .init(type: String.self),
                    isOptional: true
                ),
            ]
        )
    }

    func call(arguments: GeneratedContent) async throws -> String {
        let command = try arguments.value(String.self, forProperty: "command")
        // Only what was offered: the model is asked to choose from the read-only
        // list, and a command that is not on it does not run.
        guard commands.contains(where: { $0.path == command }) else {
            return "mywant cannot do that, or it changes something: \(command)"
        }
        var extraArgv: [String] = []
        // `do` is not run here at all: it is handed back, with the words as
        // they were said.
        //
        // It used to shell out to `mywant do`, which made a want of the
        // request and waited on it — a tile on the board for every question
        // the robot was asked, and this turn blocked while a second
        // conversation with the same model tried to start inside it. The
        // caller has the goal loop and can run it the moment this turn is
        // over; all it needs from here is the request itself, unparaphrased
        // (see GoalBox and CurrentRequest).
        if command == "do", let said = await request?.words(), !said.isEmpty {
            await goals?.hand(over: said)
            FileHandle.standardError.write(("[goal] " + said + "\n").data(using: .utf8)!)
            return "Handed to the board, which is working it out now. "
                + "Say only that you are on it — do not describe what will happen, "
                + "and do not answer the question yourself."
        }
        if let extra = try? arguments.value(String.self, forProperty: "args"), !extra.isEmpty {
            // One argument, unless the command's usage line asks for more.
            //
            // Split on spaces, "transit search" reached a command that takes
            // exactly one name as two of them, and the CLI refused it — for a
            // want whose tile was on the board the whole time. A name with a
            // space in it is still one name; only a command whose usage names
            // two placeholders gets the words handed over separately.
            let placeholders = (commands.first { $0.path == command }?.use ?? "")
                .filter { $0 == "<" || $0 == "[" }
                .count
            // Flags are words of their own however the usage line reads:
            // `wants create` takes no placeholders and everything it needs is
            // flags, so handing it "--type button --at 3,4" as one argument
            // gave the CLI one very long type name.
            let hasFlags = extra.hasPrefix("-") || extra.contains(" -")
            if placeholders > 1 || hasFlags {
                extraArgv = extra.split(separator: " ").map(String.init)
            } else {
                extraArgv = [extra]
            }
        }
        let sentence = (["mywant", command] + extraArgv).joined(separator: " ")
        // What was actually run, on stderr beside the "[tool: …]" line. Without
        // it a wrong answer is a mystery: the tool fired, and nothing says
        // whether the model asked for the wrong command or passed the whole
        // question where a name belonged.
        FileHandle.standardError.write(("[" + sentence + "]\n").data(using: .utf8)!)

        var text: String
        var failed: Bool
        if let answer = await Broker.shared.run(command: command, args: extraArgv) {
            text = answer.output.trimmingCharacters(in: .whitespacesAndNewlines)
            failed = !answer.ok
            // Not run at all — refused, or waiting for a person to say yes.
            // Handed back word for word: the reply is written for the model to
            // relay, and the usage coaching below is about a command that ran.
            if !answer.ran {
                return text.isEmpty ? "NOT RUN — mywant gave no reason." : text
            }
        } else {
            // Nobody is brokering: a one-shot `fmtool "question"` from a
            // terminal, where this process is the whole of the agent. It runs
            // the command itself, as it did before there was a caller to ask.
            let result = try MyWantCLI.run(binary, command.split(separator: " ").map(String.init) + extraArgv)
            failed = result.status != 0
            text = failed
                ? "ERROR: \(sentence) failed: " + result.err.trimmingCharacters(in: .whitespacesAndNewlines)
                : result.out.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // The failure worth naming, because it is the one the model makes and
        // then reports as a success: a command called with less than it names.
        // The usage line says what it wanted, so the correction is exact rather
        // than an invitation to try a different command — which is what
        // happened when it only said "failed": three commands in a row, none of
        // them given a cell.
        if failed {
            let usage = commands.first { $0.path == command }?.use ?? ""
            let wanted = usage.split(separator: " ").dropFirst().joined(separator: " ")
            let given = extraArgv.joined(separator: " ")
            if !wanted.isEmpty {
                text = "ERROR: '\(command)' takes \(wanted) — "
                    + (given.isEmpty ? "nothing was given" : "you gave \"\(given)\"")
                    + ", so nothing happened. Call '\(command)' again with `args` holding all of it, "
                    + "space-separated, and nothing else."
            }
        }
        if text.isEmpty { return sentence + " printed nothing" }
        // The same clip ReadFileTool uses: on-device context is ~8k tokens and a
        // want list can run to tens of KB.
        return text.count > Self.outputLimit
            ? String(text.prefix(Self.outputLimit)) + "\n...(truncated)"
            : text
    }
}
