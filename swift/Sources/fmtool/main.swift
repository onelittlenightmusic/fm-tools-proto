import Foundation
import FoundationModels

func printErr(_ s: String) {
    FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
}

let systemInstructions = """
You are the guide to this Mac and to the MyWant board on it. A guide does not \
recite; a guide shows. When something can be pointed at, point at it, and then \
say what you pointed at.

You have tools for the clock, arithmetic, the filesystem, host info, and for \
MyWant — its wants, things (named values), canvas, worlds and server. Use them \
rather than guessing, and use MORE THAN ONE when a question needs more than \
one: look something up, then act on what you found, then answer. Finishing \
after a single tool call is rarely the whole of an answer.

Anything about MyWant, a want, a thing or the board goes to the mywant tool, \
never to the file search. The board is not a pile of separate tiles: a want \
reads the things it names and the fields of other wants, and feeds its own \
fields on, so "what is X connected to" has an answer to look up. Not everything is about MyWant, though: remarks, \
greetings and questions about what was just said are answered from the \
conversation, with no tool at all.

Where something is on the board is a question to be SHOWN, not read out as \
coordinates. Work out the steps that answer it and take them; the words of a \
question are rarely the name of a tile, so what a tool reports beats what the \
question called it.

Answer in the language the question was asked in. Report what the tool told \
you — the answer, not the question back, and never the command you would run. \
Say only what a tool told you or what you were told here; if the tool could not \
answer, say that it could not, and never fill the gap from your own knowledge \
of the world. Keep answers short.
"""

// MARK: - CLI arguments

var arguments = Array(CommandLine.arguments.dropFirst())
var rootPath = FileManager.default.currentDirectoryPath
var evalCount: Int?
var forceRescue = false
var serveMode = false
var promptParts: [String] = []

var argIndex = 0
while argIndex < arguments.count {
    let arg = arguments[argIndex]
    switch arg {
    case "--root":
        argIndex += 1
        guard argIndex < arguments.count else { printErr("--root requires a path"); exit(1) }
        rootPath = arguments[argIndex]
    case "--eval":
        argIndex += 1
        guard argIndex < arguments.count, let n = Int(arguments[argIndex]) else {
            printErr("--eval requires a number")
            exit(1)
        }
        evalCount = n
    case "--rescue":
        forceRescue = true
    case "--serve":
        // Stay alive and keep one session, answering questions off stdin. See
        // Serve.swift.
        serveMode = true
    default:
        promptParts.append(arg)
    }
    argIndex += 1
}

let availability = SystemLanguageModel.default.availability
guard case .available = availability else {
    printErr("System model unavailable: \(availability)")
    exit(1)
}

let sandbox = Sandbox(root: URL(fileURLWithPath: rootPath))

// What the MyWant CLI says it can do, asked once at startup rather than at
// every request: the tool schema is built from it, and building a schema is not
// something to spend a subprocess on per question. See MyWantCLI.swift for why
// the list is read from the binary at all.
// Writing is on unless it is turned off: a robot that can only describe a board
// is not much of a hand on it, and everything it can reach either undoes
// (`mywant undo`) or is stopped by the caller until a person says yes (see
// Broker.swift).
let allowWrites = ProcessInfo.processInfo.environment["MYWANT_ROBOT_WRITE"] != "0"
let myWantCommands = MyWantCLI.offered(writes: allowWrites)
let currentRequest = CurrentRequest()
let goalBox = GoalBox()
// What this agent can reach, said once at startup: a wrong answer about the
// board is a different bug depending on whether the verb was even offered.
printErr("[fmtool] \(myWantCommands.count) mywant commands offered"
         + (allowWrites ? "" : " (reading only)"))

func makeTools(tracker: CallTracker) -> (localTools: [any LocalTool], tools: [any Tool]) {
    var localTools: [any LocalTool] = [
        TrackedTool(base: GetTimeTool(), tracker: tracker),
        TrackedTool(base: CalcTool(), tracker: tracker),
        TrackedTool(base: ListDirTool(sandbox: sandbox), tracker: tracker),
        TrackedTool(base: ReadFileTool(sandbox: sandbox), tracker: tracker),
        TrackedTool(base: SearchTool(sandbox: sandbox), tracker: tracker),
        TrackedTool(base: HostInfoTool(), tracker: tracker),
        TrackedTool(base: MyWantStartTool(), tracker: tracker),
        TrackedTool(base: MyWantDeployTool(), tracker: tracker),
    ]
    // One tool for the rest of MyWant, offering the commands this CLI actually
    // has. Absent when there is no CLI here to ask — the other tools still work.
    if let cli = MyWantCLITool(commands: myWantCommands, request: currentRequest, goals: goalBox) {
        localTools.append(TrackedTool(base: cli, tracker: tracker))
    }
    let tools: [any Tool] = localTools.map { $0 as any Tool }
    return (localTools, tools)
}

struct RunOutcome {
    let native: Bool
    let text: String
    let toolUsed: String?
}

/// Native-first, rescue-on-miss: try the framework's own Tool dispatch, and
/// only fall back to Guided Generation if nothing fired by the time the
/// model finished responding (tracker.count stayed at 0).
func run(prompt: String, forceRescue: Bool = false) async throws -> RunOutcome {
    let tracker = CallTracker()
    let (localTools, tools) = makeTools(tracker: tracker)

    if !forceRescue {
        let session = LanguageModelSession(tools: tools, instructions: systemInstructions)
        do {
            let response = try await session.respond(to: prompt)
            if await tracker.count > 0 {
                return RunOutcome(native: true, text: response.content, toolUsed: await tracker.lastToolName)
            }
        } catch {
            // A native turn can end in no answer at all rather than in a wrong
            // one: the framework's own tool loop retries, the transcript grows,
            // and the request comes back "Provided 56,113 tokens, but the
            // maximum allowed is 8,192" — for a four-word question, before a
            // single tool had run. Whatever the reason, the rescue path below
            // starts a fresh session and is exactly what this situation needs;
            // failing here instead left the asker with silence.
            printErr("[native attempt failed: \(error.localizedDescription) — falling back to rescue]")
        }
    }

    // Nothing fired on its own, so ask for a plan and carry it out. This is
    // where a question that takes two steps gets them — from the model, not
    // from a procedure written into a tool's description. See Plan.swift.
    let planSession = LanguageModelSession(tools: tools, instructions: systemInstructions)
    do {
        let planned = try await planRespond(session: planSession, prompt: prompt, tools: localTools)
        if planned.toolUsed != nil {
            return RunOutcome(native: false, text: planned.finalText, toolUsed: planned.toolUsed)
        }
    } catch {
        printErr("[plan failed: \(error.localizedDescription) — falling back to one tool]")
    }

    // A plan that named nothing runnable still leaves the question asked: the
    // older one-tool path is the floor under all of this.
    let rescueSession = LanguageModelSession(tools: tools, instructions: systemInstructions)
    let rescued = try await rescueRespond(session: rescueSession, prompt: prompt, tools: localTools)
    return RunOutcome(native: false, text: rescued.finalText, toolUsed: rescued.toolName)
}

// MARK: - Eval harness

struct EvalCase {
    let toolName: String
    let prompt: String
}

let evalCases: [EvalCase] = [
    EvalCase(toolName: "get_time", prompt: "What time is it right now on this Mac?"),
    EvalCase(toolName: "calc", prompt: "What is (17 + 5) * 3?"),
    EvalCase(toolName: "list_dir", prompt: "List the files in the current directory."),
    EvalCase(toolName: "read_file", prompt: "Read the file named eval_fixture.txt and tell me what it says."),
    EvalCase(toolName: "search", prompt: "Search the sandbox for the word \"needle\" and tell me which file it's in."),
    EvalCase(toolName: "host_info", prompt: "What is the hostname and OS version of this Mac?"),
    EvalCase(toolName: "mywant_cli", prompt: "Is the MyWant server running right now?"),
    EvalCase(toolName: "mywant_cli", prompt: "List all the MyWant wants currently running."),
    EvalCase(toolName: "mywant_cli", prompt: "How many things are named in MyWant?"),
    EvalCase(toolName: "mywant_cli", prompt: "List all registered MyWant agent capabilities."),
    EvalCase(toolName: "mywant_deploy", prompt: "List the available MyWant recipes."),
]

func runEval(count: Int) async {
    var totalNative = 0
    var totalRescued = 0
    var totalRuns = 0

    for evalCase in evalCases {
        var native = 0
        var rescued = 0
        for _ in 0..<count {
            do {
                let outcome = try await run(prompt: evalCase.prompt)
                if outcome.toolUsed == evalCase.toolName {
                    if outcome.native { native += 1 } else { rescued += 1 }
                }
            } catch {
                printErr("[\(evalCase.toolName)] error: \(error.localizedDescription)")
            }
        }
        totalNative += native
        totalRescued += rescued
        totalRuns += count
        let hit = native + rescued
        print("\(evalCase.toolName): native \(native)/\(count), +rescued \(rescued), total \(hit)/\(count)")
    }
    let totalHit = totalNative + totalRescued
    print("---")
    print("native only:    \(totalNative)/\(totalRuns)")
    print("native+rescue:  \(totalHit)/\(totalRuns)")
}

// MARK: - Entry point

if serveMode {
    await serve(makeTools: makeTools, instructions: systemInstructions, said: currentRequest, goals: goalBox)
} else if let n = evalCount {
    await runEval(count: n)
} else {
    let prompt = promptParts.joined(separator: " ")
    guard !prompt.isEmpty else {
        printErr("usage: fmtool [--root <path>] [--eval <n>] [--serve] <prompt>")
        exit(1)
    }
    do {
        let outcome = try await run(prompt: prompt, forceRescue: forceRescue)
        if let tool = outcome.toolUsed {
            printErr("[tool: \(tool), native: \(outcome.native)]")
        }
        print(outcome.text)
    } catch {
        printErr("error: \(error.localizedDescription)")
        exit(1)
    }
}
