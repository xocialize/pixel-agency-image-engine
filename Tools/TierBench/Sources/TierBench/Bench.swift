import Foundation
import MESClientKit
import MESCore

/// One measured run.
struct Record: Codable {
    var suite: String
    var operation: String
    var item: String
    /// The model the request named, or nil for the engine's choice at `quality`.
    var requested: String?
    var quality: String?
    /// The model that ran (the job's plan).
    var model: String
    var runMs: Int
    var warm: Bool
    var metrics: [String: Double] = [:]
    var warnings: [String] = []
    var outputs: [String] = []
    var error: String?
}

/// A running engine, driven the way a client drives it.
final class Bench: @unchecked Sendable {
    let connection: HTTPEngineConnection
    let info: EngineInfo
    let operations: [Descriptor]
    let out: URL
    private let log: FileHandle
    private(set) var records: [Record] = []

    init(engine: URL, out: URL) async throws {
        connection = HTTPEngineConnection(baseURL: engine)
        info = try await connection.engineInfo()
        operations = try await connection.operations().operations
        self.out = out
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let path = out.appendingPathComponent("results.jsonl")
        if !FileManager.default.fileExists(atPath: path.path) { FileManager.default.createFile(atPath: path.path, contents: nil) }
        log = try FileHandle(forWritingTo: path)
        log.seekToEndOfFile()
    }

    func offers(_ operation: String) -> [ModelOffer] { operations.first { $0.operation == operation }?.models ?? [] }

    enum Input { case file(URL), text(String), data(JSONValue) }

    /// Runs one job, downloads its outputs into `folder`, confirms it, and records it.
    @discardableResult
    func run(suite: String, operation: String, item: String, inputs: [String: Input], params: [String: JSONValue] = [:],
             model: String? = nil, quality: QualityTier? = nil, warm: Bool = true, folder: String,
             score: (([URL]) throws -> [String: Double])? = nil) async -> Record {
        var record = Record(suite: suite, operation: operation, item: item, requested: model, quality: quality?.rawValue,
                            model: model ?? "?", runMs: 0, warm: warm)
        do {
            var request: [String: RequestInput] = [:]
            for (name, input) in inputs {
                switch input {
                case .text(let s): request[name] = .text(s)
                case .data(let v): request[name] = .one(.data(v))
                case .file(let url):
                    request[name] = .one(try await connection.input(contentsOf: url, inlineLimit: info.limits.maxInlineBytes))
                }
            }
            var p = params
            if let quality { p["quality"] = .string(quality.rawValue) }
            let job = try await connection.run(JobRequest(operation: operation, inputs: request, params: p.isEmpty ? nil : p, model: model))
            record.model = job.plan?.model.id ?? record.model
            record.runMs = job.result?.provenance.timings.runMs ?? 0
            record.warnings = job.warnings.map(\.code)
            guard job.outcome == .succeeded else {
                record.error = job.error.map { "\($0.code): \($0.message)" } ?? "\(job.state.rawValue)"
                throw BenchError(record.error!)
            }
            let dir = out.appendingPathComponent(folder)
            let files = try await connection.downloadAll(job, to: dir)
            record.outputs = files.map { $0.path.replacingOccurrences(of: out.path + "/", with: "") }
            for output in job.result?.outputs ?? [] where output.value != nil {
                if let v = output.value?["score"]?.numberValue { record.metrics["score"] = v }
            }
            _ = try? await connection.confirm(job.id)
            if let score { record.metrics.merge(try score(files)) { $1 } }
        } catch {
            record.error = record.error ?? "\(error)"
        }
        records.append(record)
        if let line = try? JSONEncoder().encode(record) { log.write(line + Data("\n".utf8)) }
        let m = record.metrics.sorted { $0.key < $1.key }.map { "\($0.key)=\(String(format: "%.4g", $0.value))" }.joined(separator: " ")
        print("\(suite) \(operation) \(record.model)\(quality.map { " [\($0.rawValue)]" } ?? "") \(item): \(record.runMs) ms \(m)\(record.error.map { " ERROR \($0)" } ?? "")")
        return record
    }

    func updateRecord(_ index: Int, _ change: (inout Record) -> Void) { change(&records[index]) }

    func appendRecord(_ record: Record) {
        records.append(record)
        if let line = try? JSONEncoder().encode(record) { log.write(line + Data("\n".utf8)) }
    }

    /// The engine process's physical footprint in GB (`footprint`), or nil.
    func footprintGB() -> Double? {
        let pgrep = Process()
        pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        pgrep.arguments = ["-f", "pixel-agency-image-engine"]
        let pipe = Pipe(); pgrep.standardOutput = pipe
        try? pgrep.run(); pgrep.waitUntilExit()
        guard let pid = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(separator: "\n").first.map(String.init) else { return nil }
        let fp = Process()
        fp.executableURL = URL(fileURLWithPath: "/usr/bin/footprint")
        fp.arguments = ["-p", pid]
        let out = Pipe(); fp.standardOutput = out; fp.standardError = Pipe()
        try? fp.run(); fp.waitUntilExit()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard let line = text.split(separator: "\n").first(where: { $0.contains("phys_footprint:") }) else { return nil }
        let parts = line.split(separator: " ")
        guard let i = parts.firstIndex(where: { $0.hasPrefix("phys_footprint") }), i + 2 < parts.count, let v = Double(parts[i + 1]) else { return nil }
        switch parts[i + 2] { case "GB": return v; case "MB": return v / 1024; case "KB": return v / 1_048_576; default: return nil }
    }
}

/// The summary: per suite and model, the mean of each metric and the median warm time.
enum Summary {
    static func markdown(_ records: [Record], footprints: [String: Double]) -> String {
        var md = ""
        let suites = Array(Set(records.map(\.suite))).sorted()
        for suite in suites {
            let rs = records.filter { $0.suite == suite }
            let metricNames = Array(Set(rs.flatMap(\.metrics.keys))).sorted()
            md += "\n### \(suite)\n\n| Operation | Model | Tier | Runs | Median warm (ms) | First run (ms) | " + metricNames.joined(separator: " | ")
                + " | Footprint (GB) | Errors |\n|" + String(repeating: "---|", count: 8 + metricNames.count) + "\n"
            let keys = Array(Set(rs.map { "\($0.operation)|\($0.model)|\($0.quality ?? ($0.requested == nil ? "default" : "named"))" })).sorted()
            for key in keys {
                let parts = key.split(separator: "|").map(String.init)
                let group = rs.filter { "\($0.operation)|\($0.model)|\($0.quality ?? ($0.requested == nil ? "default" : "named"))" == key }
                let ok = group.filter { $0.error == nil }
                let warm = ok.filter(\.warm).map(\.runMs).sorted()
                let median = warm.isEmpty ? "—" : "\(warm[warm.count / 2])"
                let first = group.first { !$0.warm }.map { "\($0.runMs)" } ?? "—"
                let means = metricNames.map { name -> String in
                    let v = ok.compactMap { $0.metrics[name] }
                    return v.isEmpty ? "—" : String(format: "%.4f", v.reduce(0, +) / Double(v.count))
                }
                let fp = footprints[parts[1]].map { String(format: "%.1f", $0) } ?? "—"
                md += "| \(parts[0]) | \(parts[1]) | \(parts[2]) | \(ok.count) | \(median) | \(first) | " + means.joined(separator: " | ")
                    + " | \(fp) | \(group.count - ok.count) |\n"
            }
        }
        return md
    }
}
