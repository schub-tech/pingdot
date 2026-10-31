import Foundation

/// What PingDot saw during one minute — the unit the history window draws.
struct MinuteRecord: Codable {
    /// Start of the minute, seconds since 1970.
    var start: TimeInterval

    // Seconds the dot spent in each colour. Seconds the Mac slept (or PingDot
    // was not running) count nowhere — that is the "not measured" grey.
    var good = 0
    var unstable = 0
    var down = 0

    // Probes of the best target in this minute. Same idea as the dot: one
    // provider having a bad day is not your connection having one.
    var probes = 0
    var lost = 0
    var rttSum: TimeInterval = 0
    var rttCount = 0
    var rttMax: TimeInterval?

    var observed: Int { good + unstable + down }
    var averageRTT: TimeInterval? { rttCount > 0 ? rttSum / Double(rttCount) : nil }
    var lossPercent: Double? { probes > 0 ? Double(lost) / Double(probes) * 100 : nil }

    /// Adds another minute's counters, for drawing several minutes as one bar.
    mutating func merge(_ other: MinuteRecord) {
        good += other.good
        unstable += other.unstable
        down += other.down
        probes += other.probes
        lost += other.lost
        rttSum += other.rttSum
        rttCount += other.rttCount
        if let max = other.rttMax { rttMax = Swift.max(rttMax ?? 0, max) }
    }
}

/// The last 24 hours, one record per minute, kept in a small JSON file so a
/// restart does not wipe the train ride you want to look at.
final class History: ObservableObject {
    static let retention: TimeInterval = 24 * 3600

    /// Closed minutes, oldest first.
    private(set) var records: [MinuteRecord] = []

    /// Closed minutes plus the one in progress.
    var minutes: [MinuteRecord] {
        guard let current, current.observed > 0 || current.probes > 0 else { return records }
        return records + [current]
    }

    private struct Tally {
        var probes = 0
        var lost = 0
        var rttSum: TimeInterval = 0
        var rttCount = 0
        var rttMax: TimeInterval?
    }

    private var current: MinuteRecord?
    private var tallies: [String: Tally] = [:]   // per target, current minute only
    private var ticksSincePublish = 0
    private let fileURL: URL?
    private let saveQueue = DispatchQueue(label: "tech.schub.pingdot.history", qos: .utility)

    init(fileURL: URL? = History.defaultURL) {
        self.fileURL = fileURL
        load()
    }

    /// `~/Library/Application Support/PingDot/history.json` — inside the
    /// container for the sandboxed builds.
    static var defaultURL: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("PingDot", isDirectory: true)
            .appendingPathComponent("history.json")
    }

    // MARK: - Recording

    /// One probe result from one target.
    func addProbe(host: String, ok: Bool, rtt: TimeInterval?, at date: Date = Date()) {
        roll(to: date)
        var tally = tallies[host, default: Tally()]
        tally.probes += 1
        if ok, let rtt {
            tally.rttSum += rtt
            tally.rttCount += 1
            tally.rttMax = max(tally.rttMax ?? 0, rtt)
        } else if !ok {
            tally.lost += 1
        }
        tallies[host] = tally
    }

    /// Called once a second with the colour of the dot.
    func tick(health: Health, at date: Date = Date()) {
        roll(to: date)
        switch health {
        case .green: current?.good += 1
        case .yellow: current?.unstable += 1
        case .red: current?.down += 1
        case .unknown: break
        }

        // An open window shows the minute in progress too, but redrawing the
        // chart every second would be wasteful.
        ticksSincePublish += 1
        if ticksSincePublish >= 10 {
            ticksSincePublish = 0
            objectWillChange.send()
        }
    }

    /// Close the current minute once the clock has moved past it. After sleep
    /// this simply jumps ahead and leaves a gap.
    private func roll(to date: Date) {
        let minute = (date.timeIntervalSince1970 / 60).rounded(.down) * 60
        if current?.start == minute { return }

        if var finished = current {
            applyBestTally(to: &finished)
            if finished.observed > 0 || finished.probes > 0 {
                records.append(finished)
            }
            prune(now: date)
            objectWillChange.send()
            save()
        }
        current = MinuteRecord(start: minute)
        tallies.removeAll()
    }

    /// The target with the least loss (then the fastest) speaks for the minute.
    private func applyBestTally(to record: inout MinuteRecord) {
        let best = tallies.values
            .filter { $0.probes > 0 }
            .min { a, b in
                let lossA = Double(a.lost) / Double(a.probes)
                let lossB = Double(b.lost) / Double(b.probes)
                if lossA != lossB { return lossA < lossB }
                let avgA = a.rttCount > 0 ? a.rttSum / Double(a.rttCount) : .infinity
                let avgB = b.rttCount > 0 ? b.rttSum / Double(b.rttCount) : .infinity
                return avgA < avgB
            }
        guard let best else { return }
        record.probes = best.probes
        record.lost = best.lost
        record.rttSum = best.rttSum
        record.rttCount = best.rttCount
        record.rttMax = best.rttMax
    }

    private func prune(now: Date) {
        let cutoff = now.timeIntervalSince1970 - Self.retention
        if let first = records.firstIndex(where: { $0.start >= cutoff }) {
            if first > 0 { records.removeFirst(first) }
        } else {
            records.removeAll()
        }
    }

    // MARK: - Persistence

    private func load() {
        guard let fileURL, let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode([MinuteRecord].self, from: data) else { return }
        records = stored.sorted { $0.start < $1.start }
        prune(now: Date())
    }

    /// Writes the closed minutes. `sync` is for quitting, where a background
    /// write might not finish.
    func save(sync: Bool = false) {
        guard let fileURL, let data = try? JSONEncoder().encode(records) else { return }
        let write = {
            try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(),
                                                     withIntermediateDirectories: true)
            try? data.write(to: fileURL, options: .atomic)
        }
        if sync { saveQueue.sync(execute: write) } else { saveQueue.async(execute: write) }
    }
}
