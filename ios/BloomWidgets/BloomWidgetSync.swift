import Foundation
import WidgetKit
import CryptoKit
import Darwin

/// A refill transport for the shared cache, not a separate playback engine.
/// WidgetKit delivers background URLSession events to this extension even when
/// Flutter is absent. A completed download only joins the canonical timeline
/// after the original and every widget size are ready and identity-checked.
final class BloomWidgetSync: NSObject, URLSessionDownloadDelegate {
    static let shared = BloomWidgetSync()
    static let sessionID = "com.zhangbo.bloom.widgets.refill.v1"
    private let base = URL(string: "https://bloom.jihu.top")!
    private let sessionLock = NSLock()
    private var storedSession: URLSession?
    private var eventsCompletions: [() -> Void] = []
    private let eventsLock = NSLock()
    private var changed = false

    private var session: URLSession {
        sessionLock.lock(); defer { sessionLock.unlock() }
        if let storedSession { return storedSession }
        let configuration = URLSessionConfiguration.background(withIdentifier: Self.sessionID)
        configuration.sharedContainerIdentifier = BloomSharedState.appGroup
        configuration.isDiscretionary = false
        configuration.sessionSendsLaunchEvents = true
        configuration.httpMaximumConnectionsPerHost = 2
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 180
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        let value = URLSession(configuration: configuration, delegate: self, delegateQueue: queue)
        storedSession = value
        return value
    }

    func handleEvents(identifier: String, completion: @escaping () -> Void) {
        guard identifier == Self.sessionID else { completion(); return }
        eventsLock.lock(); eventsCompletions.append(completion); eventsLock.unlock()
        _ = session
    }

    static func fingerprint(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func epoch(in directory: URL) -> String? {
        BloomSharedState.readJSON(directory.appendingPathComponent("content-sync-epoch.json"))?["token"] as? String
    }

    private func valid(_ job: [String: Any], directory: URL, defaults: UserDefaults) -> Bool {
        guard !defaults.bool(forKey: "bloom.signed_out"),
              job["device"] as? String == defaults.string(forKey: "bloom.device_id"),
              let token = defaults.string(forKey: "bloom.device_token"), !token.isEmpty,
              job["credential"] as? String == Self.fingerprint(token),
              job["epoch"] as? String == epoch(in: directory) else { return false }
        return job["pipeline"] as? String == "carousel"
    }

    /// Register background work before returning a cached timeline. Metadata,
    /// preparation and photos all survive extension suspension in one session.
    func refill() {
        guard let directory = BloomSharedState.cacheDirectory(),
              let defaults = UserDefaults(suiteName: BloomSharedState.appGroup),
              !defaults.bool(forKey: "bloom.signed_out"),
              let device = defaults.string(forKey: "bloom.device_id"),
              let token = defaults.string(forKey: "bloom.device_token"), token.count >= 32 else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        let lease = BloomSharedFileLock(directory.appendingPathComponent("carousel-sync.lock"))
        if lease.acquire() {
            consumeMetadata(directory: directory, defaults: defaults, lease: lease)
            consumeStaged(directory: directory, defaults: defaults, lease: lease, budget: 1)
            lease.release()
        } else {
            // Network registration does not publish or prune shared files.
            // Register it even while Flutter prepares a batch: that process
            // may be killed as soon as the user leaves its settings page.
            log("refill busy \(lease.failureDescription); registering background continuation")
        }
        var job = context(device: device, token: token, directory: directory)
        let probeData = (try? JSONSerialization.data(withJSONObject: job, options: [.sortedKeys])) ?? Data()
        let probeContext = Self.fingerprint(String(decoding: probeData, as: UTF8.self))
        let last = defaults.double(forKey: "bloom.widgetRefillProbeAt")
        if defaults.string(forKey: "bloom.widgetRefillProbeContext") == probeContext,
           Date().timeIntervalSince1970 - last < 60 { return }
        defaults.set(Date().timeIntervalSince1970, forKey: "bloom.widgetRefillProbeAt")
        defaults.set(probeContext, forKey: "bloom.widgetRefillProbeContext")
        job["kind"] = "settings"
        queue(job, path: devicePath(device, "carousel/settings/get"), token: token, body: ["target": "mobile"])
        coalesceTasks(directory: directory, defaults: defaults)
    }

    private func context(device: String, token: String, directory: URL) -> [String: Any] {
        ["device": device, "credential": Self.fingerprint(token),
         "epoch": epoch(in: directory) ?? NSNull(), "pipeline": "carousel"]
    }

    private func planBody(defaults: UserDefaults) -> [String: Any] {
        ["target": "mobile", "batch_limit": 200, "timezone": "Asia/Shanghai",
         "interval_minutes": max(1, defaults.integer(forKey: "bloom.carousel_interval_minutes")),
         "active_start": defaults.string(forKey: "bloom.carousel_active_start") ?? "06:00",
         "active_end": defaults.string(forKey: "bloom.carousel_active_end") ?? "22:00",
         "cached_item_ids": (BloomSharedState.load()?["photos"] as? [[String: Any]] ?? []).compactMap { $0["item_id"] }]
    }

    private func consumeMetadata(directory: URL, defaults: UserDefaults, lease: BloomSharedFileLock) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("widget-refill-") && file.pathExtension == "metadata" {
            guard lease.isHeld(), let staged = BloomSharedState.readJSON(file),
                  let job = staged["job"] as? [String: Any],
                  let payload = staged["payload"] as? [String: Any] else { continue }
            guard valid(job, directory: directory, defaults: defaults) else {
                try? FileManager.default.removeItem(at: file); continue
            }
            do {
                try processMetadata(job, payload: payload, directory: directory, defaults: defaults, lease: lease)
                try? FileManager.default.removeItem(at: file)
            } catch SyncError.busy {
                // Keep the response for the next provider or download callback.
            } catch {
                try? FileManager.default.removeItem(at: file)
                log("metadata discarded \(error.localizedDescription)")
            }
        }
    }

    private func processMetadata(_ job: [String: Any], payload: [String: Any], directory: URL, defaults: UserDefaults, lease: BloomSharedFileLock) throws {
        guard valid(job, directory: directory, defaults: defaults),
              let device = job["device"] as? String,
              let token = defaults.string(forKey: "bloom.device_token") else { throw SyncError.superseded }
        switch job["kind"] as? String {
        case "settings":
            guard let settings = payload["settings"] as? [String: Any] else { throw SyncError.json }
            try adoptSettings(settings, directory: directory, defaults: defaults)
            var next = context(device: device, token: token, directory: directory)
            next["kind"] = "plan"
            let body = planBody(defaults: defaults); next["body"] = body
            queue(next, path: devicePath(device, "carousel/plan"), token: token, body: body)
        case "plan":
            try refillPlan(job, payload: payload, directory: directory, defaults: defaults, token: token, lease: lease)
        case "prepare":
            guard let item = payload["item"] as? [String: Any],
                  let id = item["item_id"] as? Int,
                  id == (job["item"] as? [String: Any])?["item_id"] as? Int,
                  let plan = job["plan"] as? [String: Any],
                  BloomSharedState.planId(BloomSharedState.load() ?? [:]) == (plan["plan_id"] as? NSNumber)?.intValue else { throw SyncError.superseded }
            var next = job; next["kind"] = "photo"; next["item"] = item
            var grid = BloomSharedState.grid(BloomSharedState.load() ?? [:])
            if let index = grid.firstIndex(where: { ($0["item_id"] as? Int) == id }) { grid[index]["asset_id"] = item["asset_id"] }
            try commitPlan(job, plan: plan, grid: grid, ready: [], serverNext: (job["server_next"] as? NSNumber)?.doubleValue, directory: directory, defaults: defaults, lease: lease)
            queue(next, path: devicePath(device, "carousel/photo"), token: token, body: ["item_id": id])
        default: throw SyncError.json
        }
    }

    private func adoptSettings(_ settings: [String: Any], directory: URL, defaults: UserDefaults) throws {
        let mode = settings["mode"] as? String ?? defaults.string(forKey: "bloom.display_mode") ?? "recommend"
        let sources = (settings["sources"] as? [Any] ?? ["personal"]).compactMap { raw -> String? in
            if let string = raw as? String { return string }
            let object = raw as? [String: Any]
            return (object?["name"] ?? object?["id"]) as? String
        }.filter { ["personal", "art", "news", "widget"].contains($0) }.sorted()
        let actualSources = sources.isEmpty ? ["personal"] : sources
        let interval = (settings["interval_minutes"] as? NSNumber)?.intValue ?? 1440
        let start = settings["active_start"] as? String ?? "06:00"
        let end = settings["active_end"] as? String ?? "22:00"
        let timezone = settings["timezone"] as? String ?? "Asia/Shanghai"
        let key = String(data: try JSONSerialization.data(withJSONObject: [mode == "carousel" ? "carousel" : "recommendation", interval, start, end, timezone, actualSources], options: [.withoutEscapingSlashes]), encoding: .utf8)!
        let epochURL = directory.appendingPathComponent("content-sync-epoch.json")
        let epochLock = BloomSharedFileLock(directory.appendingPathComponent("content-sync-epoch.lock"))
        guard epochLock.acquire() else { throw SyncError.busy }
        defer { epochLock.release() }
        let stateLock = BloomSharedFileLock(directory.appendingPathComponent("carousel-state.lock"))
        guard stateLock.acquire() else { throw SyncError.busy }
        defer { stateLock.release() }
        if BloomSharedState.readJSON(epochURL)?["settings"] as? String != key {
            var state = BloomSharedState.load() ?? [:]
            let now = Date().timeIntervalSince1970 * 1000
            let past = BloomSharedState.timelineEntries(state).filter { (($0["date_ms"] as? NSNumber)?.doubleValue ?? 0) <= now }
                .sorted { (($0["date_ms"] as? NSNumber)?.doubleValue ?? 0) < (($1["date_ms"] as? NSNumber)?.doubleValue ?? 0) }
            let fallback = Array(past.suffix(2))
            state["plan"] = NSNull(); state["grid"] = []; state["timeline_entries"] = fallback
            if let last = fallback.last {
                state["current_item_id"] = last["item_id"]
                state["current_photo_path"] = last["portrait_path"]
                state["current_slot_at_ms"] = last["date_ms"]
            }
            var retained = Set(fallback.compactMap { ($0["item_id"] as? NSNumber)?.intValue })
            if fallback.isEmpty, let id = state["current_item_id"] as? Int { retained.insert(id) }
            state["photos"] = (state["photos"] as? [[String: Any]] ?? []).filter { retained.contains(($0["item_id"] as? NSNumber)?.intValue ?? -1) }
            state["previous_item_id"] = fallback.count > 1 ? fallback.first?["item_id"] ?? NSNull() : NSNull()
            state["next_slot_at_ms"] = NSNull()
            state["revision"] = ((state["revision"] as? NSNumber)?.intValue ?? 0) + 1
            try BloomSharedState.writeJSON(state, to: directory.appendingPathComponent(BloomSharedState.fileName))
            try BloomSharedState.writeJSON(["settings": key, "token": String(Int64(Date().timeIntervalSince1970 * 1_000_000))], to: epochURL)
            let projectionURL = directory.appendingPathComponent("daily.json")
            if var projection = BloomSharedState.readJSON(projectionURL) {
                projection["next_slot_at_ms"] = NSNull()
                try BloomSharedState.writeJSON(projection, to: projectionURL)
            }
            prune(directory: directory)
        }
        defaults.set(mode, forKey: "bloom.display_mode")
        defaults.set(actualSources, forKey: "bloom.content_sources")
        defaults.set(true, forKey: "bloom.scheduled_plan")
        defaults.set(interval, forKey: "bloom.carousel_interval_minutes")
        defaults.set(start, forKey: "bloom.carousel_active_start")
        defaults.set(end, forKey: "bloom.carousel_active_end")
        defaults.synchronize()
    }

    private func refillPlan(_ context: [String: Any], payload: [String: Any], directory: URL, defaults: UserDefaults, token: String, lease: BloomSharedFileLock) throws {
        let device = context["device"] as! String
        guard lease.isHeld(), valid(context, directory: directory, defaults: defaults),
              let planID = payload["plan_id"] as? NSNumber,
              let day = payload["local_date"] as? String,
              let hash = payload["settings_hash"] as? String else { throw SyncError.superseded }
        let plan: [String: Any] = ["plan_id": planID, "day": day, "settings_hash": hash]
        let items = ((context["prior_items"] as? [[String: Any]] ?? []) + (payload["items"] as? [[String: Any]] ?? []))
            .sorted { millis($0["display_at"]) < millis($1["display_at"]) }
        if let previous = context["prior_plan"] as? NSNumber, previous != planID { throw SyncError.superseded }
        if payload["has_more"] as? Bool == true, items.count <= 4, let cursor = items.last?["item_id"] {
            var next = context; next["prior_items"] = items; next["prior_plan"] = planID
            var body = context["body"] as? [String: Any] ?? planBody(defaults: defaults)
            body["after_item_id"] = cursor; next["body"] = body
            queue(next, path: devicePath(device, "carousel/plan"), token: token, body: body)
            return
        }
        let grid: [[String: Any]] = items.map { ["item_id": $0["item_id"] ?? 0, "asset_id": $0["asset_id"] ?? "", "slot_at_ms": Int(millis($0["display_at"]))] }
        let next = millis(payload["next_check_at"])
        try commitPlan(context, plan: plan, grid: grid, ready: [], serverNext: next, directory: directory, defaults: defaults, lease: lease)
        let now = Date().timeIntervalSince1970 * 1000
        let current = items.last { millis($0["display_at"]) <= now }
        let candidates = (current.map { [$0] } ?? []) + Array(items.filter { millis($0["display_at"]) > now }.prefix(4))
        for candidate in candidates {
            guard lease.isHeld(), valid(context, directory: directory, defaults: defaults) else { break }
            guard let id = candidate["item_id"] as? Int else { continue }
            if ready(candidate, directory: directory) {
                try commitPlan(context, plan: plan, grid: grid, ready: [timelineEntry(candidate, directory: directory)], serverNext: next, directory: directory, defaults: defaults, lease: lease)
            } else {
                var job = context; job["kind"] = "prepare"
                job["plan"] = plan; job["item"] = candidate; job["server_next"] = next
                job.removeValue(forKey: "prior_items"); job.removeValue(forKey: "body")
                queue(job, path: devicePath(device, "carousel/prepare"), token: token, body: ["item_id": id])
            }
        }
        eventsLock.lock(); changed = true; eventsLock.unlock()
        coalesceTasks(directory: directory, defaults: defaults)
        log("refill plan=\(planID) candidates=\(candidates.count)")
    }

    private func coalesceTasks(directory: URL, defaults: UserDefaults) {
        session.getAllTasks { tasks in
            var keys = Set<String>()
            for task in tasks.sorted(by: { $0.taskIdentifier < $1.taskIdentifier }) {
                guard let data = task.taskDescription?.data(using: .utf8),
                      let job = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                      self.valid(job, directory: directory, defaults: defaults) else { task.cancel(); continue }
                let key: [String: Any] = ["kind": job["kind"] ?? "photo", "epoch": job["epoch"] ?? NSNull(),
                    "plan": (job["plan"] as? [String: Any])?["plan_id"] ?? NSNull(),
                    "item": (job["item"] as? [String: Any])?["item_id"] ?? NSNull(),
                    "body": job["body"] ?? NSNull()]
                guard let bytes = try? JSONSerialization.data(withJSONObject: key, options: [.sortedKeys]),
                      keys.insert(Self.fingerprint(String(decoding: bytes, as: UTF8.self))).inserted else { task.cancel(); continue }
            }
        }
    }

    private func queue(_ job: [String: Any], path: String, token: String, body: [String: Any]?) {
        guard let request = try? request(path: path, token: token, body: body),
              let description = try? JSONSerialization.data(withJSONObject: job, options: [.sortedKeys, .withoutEscapingSlashes]) else { return }
        var downloadRequest = request
        downloadRequest.timeoutInterval = 60
        let task = session.downloadTask(with: downloadRequest)
        task.taskDescription = String(data: description, encoding: .utf8)
        task.resume()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let response = downloadTask.response as? HTTPURLResponse else { return }
        guard let description = downloadTask.taskDescription?.data(using: .utf8),
              var job = (try? JSONSerialization.jsonObject(with: description)) as? [String: Any],
              let directory = BloomSharedState.cacheDirectory(),
              let defaults = UserDefaults(suiteName: BloomSharedState.appGroup), valid(job, directory: directory, defaults: defaults) else { return }
        guard response.statusCode == 200 else {
            if job["kind"] as? String == "plan", [400, 422].contains(response.statusCode),
               var body = job["body"] as? [String: Any], body["batch_limit"] as? Int != 4,
               let device = job["device"] as? String, let token = defaults.string(forKey: "bloom.device_token") {
                body["batch_limit"] = 4; job["body"] = body
                queue(job, path: devicePath(device, "carousel/plan"), token: token, body: body)
            } else { log("download response=\(response.statusCode); shared photo retained") }
            return
        }
        if let kind = job["kind"] as? String, kind != "photo" {
            do {
                let data = try Data(contentsOf: location)
                guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw SyncError.json }
                let file = directory.appendingPathComponent("widget-refill-\(UUID().uuidString).metadata")
                try BloomSharedState.writeJSON(["job": job, "payload": payload], to: file)
                eventsLock.lock(); changed = true; eventsLock.unlock()
                let lease = BloomSharedFileLock(directory.appendingPathComponent("carousel-sync.lock"))
                if lease.acquire() {
                    defer { lease.release() }
                    consumeMetadata(directory: directory, defaults: defaults, lease: lease)
                    consumeStaged(directory: directory, defaults: defaults, lease: lease)
                }
            } catch { log("metadata stage failed \(error.localizedDescription)") }
            return
        }
        let key = "widget-refill-\(UUID().uuidString)"
        let file = directory.appendingPathComponent(key + ".photo")
        let metadata = directory.appendingPathComponent(key + ".json")
        do {
            try FileManager.default.copyItem(at: location, to: file)
            job["staged_path"] = file.path
            try BloomSharedState.writeJSON(job, to: metadata)
            let lease = BloomSharedFileLock(directory.appendingPathComponent("carousel-sync.lock"))
            if lease.acquire() {
                defer { lease.release() }
                consumeStaged(directory: directory, defaults: defaults, lease: lease)
            }
            // Coalesce a batch into one reload at session completion. Staged
            // bytes remain recoverable if Flutter currently holds the lease.
            eventsLock.lock(); changed = true; eventsLock.unlock()
        } catch { try? FileManager.default.removeItem(at: file); log("stage failed \(error.localizedDescription)") }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { log("download failed \(error.localizedDescription); shared photo retained") }
        // Also completes a batch delivered while the extension is already
        // alive, without depending on a separate background wake-up event.
        session.getAllTasks { tasks in
            guard !tasks.contains(where: { $0.state == .running || $0.state == .suspended }) else { return }
            DispatchQueue.main.async {
                self.eventsLock.lock()
                let shouldReload = self.changed; self.changed = false
                self.eventsLock.unlock()
                if shouldReload { WidgetCenter.shared.reloadAllTimelines() }
            }
        }
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        eventsLock.lock()
        let completions = eventsCompletions; eventsCompletions.removeAll()
        eventsLock.unlock()
        DispatchQueue.main.async {
            self.eventsLock.lock()
            let shouldReload = self.changed; self.changed = false
            self.eventsLock.unlock()
            if shouldReload { WidgetCenter.shared.reloadAllTimelines() }
            completions.forEach { $0() }
        }
    }

    private func consumeStaged(directory: URL, defaults: UserDefaults, lease: BloomSharedFileLock, budget: TimeInterval = 12) {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        // Newest due image first; a backlog of superseded past slots must not
        // consume an extension's short budget before it can refill the present.
        let stagedJobs = files.filter { $0.lastPathComponent.hasPrefix("widget-refill-") && $0.pathExtension == "json" }
            .sorted { left, right in
                let a = (BloomSharedState.readJSON(left)?["item"] as? [String: Any])?["display_at"]
                let b = (BloomSharedState.readJSON(right)?["item"] as? [String: Any])?["display_at"]
                return millis(a) > millis(b)
            }
        let started = Date()
        for metadata in stagedJobs {
            guard lease.isHeld(), Date().timeIntervalSince(started) < budget else { break }
            guard let job = BloomSharedState.readJSON(metadata), let path = job["staged_path"] as? String else { continue }
            let staged = URL(fileURLWithPath: path)
            var discard = false
            defer {
                if discard { try? FileManager.default.removeItem(at: metadata); try? FileManager.default.removeItem(at: staged) }
            }
            guard valid(job, directory: directory, defaults: defaults), let item = job["item"] as? [String: Any],
                  let id = item["item_id"] as? Int else { discard = true; continue }

            do {
                let shared = BloomSharedState.load() ?? [:]
                let currentPlan = shared["plan"] as? [String: Any]
                let jobPlan = job["plan"] as? [String: Any]
                guard (currentPlan?["plan_id"] as? NSNumber) == (jobPlan?["plan_id"] as? NSNumber),
                      currentPlan?["settings_hash"] as? String == jobPlan?["settings_hash"] as? String else { discard = true; continue }
                let currentAt = (shared["current_slot_at_ms"] as? NSNumber)?.doubleValue ?? 0
                if millis(item["display_at"]) < currentAt { discard = true; continue }
            }
            let photoLock = BloomSharedFileLock(directory.appendingPathComponent("photo-prepare-\(id).lock"))
            guard photoLock.acquire() else { continue }
            defer { photoLock.release() }
            autoreleasepool {
                do {
                    guard let image = BloomWidgetRenderer.image(at: staged) else { discard = true; throw SyncError.image }
                    let stem = "mobile-local"
                    let original = directory.appendingPathComponent("carousel-original-\(id).photo")
                    // Render to staging paths first. A partially prepared item
                    // cannot join the timeline or replace any current picture.
                    var outputs: [(URL, URL)] = []
                    defer { for pair in outputs { try? FileManager.default.removeItem(at: pair.0) } }
                    for family in ["portrait", "square", "largeSquare"] {
                        let target = directory.appendingPathComponent("\(stem)-\(family)-\(id).png")
                        let temp = directory.appendingPathComponent("widget-render-\(UUID().uuidString).tmp")
                        try autoreleasepool {
                            guard let bytes = BloomWidgetRenderer.render(image, item: item, family: family) else { throw SyncError.image }
                            try bytes.write(to: temp, options: [.completeFileProtectionUntilFirstUserAuthentication])
                        }
                        outputs.append((temp, target))
                    }
                    let stateLock = BloomSharedFileLock(directory.appendingPathComponent("carousel-state.lock"))
                    guard stateLock.acquire() else { throw SyncError.busy }
                    defer { stateLock.release() }
                    guard lease.isHeld(), stateLock.isHeld(), valid(job, directory: directory, defaults: defaults) else { throw SyncError.superseded }
                    try Data(contentsOf: staged).write(to: original, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                    for pair in outputs {
                        guard rename(pair.0.path, pair.1.path) == 0 else { throw SyncError.image }
                        try? FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: pair.1.path)
                    }
                    do {
                        try BloomSharedState.writeJSON(["asset": item["asset_id"] ?? "", "source": item["source_name"] ?? "personal"], to: directory.appendingPathComponent("mobile-original-\(id).json"))
                        try BloomSharedState.writeJSON(["native_layout": BloomWidgetRenderer.version, "native_descriptor": descriptorFingerprint(item)], to: directory.appendingPathComponent("mobile-render-\(id).json"))
                        let entry = timelineEntry(item, directory: directory)
                        let state = BloomSharedState.load() ?? [:]
                        var grid = BloomSharedState.grid(state)
                        if let index = grid.firstIndex(where: { ($0["item_id"] as? Int) == id }) { grid[index]["asset_id"] = item["asset_id"] }
                        let merged = BloomSharedState.merging(state, plan: job["plan"] as? [String: Any] ?? [:], grid: grid, ready: [entry], nowMillis: Date().timeIntervalSince1970 * 1000, serverNext: (job["server_next"] as? NSNumber)?.doubleValue)
                        try publish(merged, directory: directory)
                    }
                    eventsLock.lock(); changed = true; eventsLock.unlock()
                    log("committed item=\(id) pipeline=carousel")
                    discard = true
                } catch { log("publication failed item=\(id) \(error.localizedDescription)") }
            }
        }
        if lease.isHeld() { prune(directory: directory) }
    }

    private func commitPlan(_ context: [String: Any], plan: [String: Any], grid: [[String: Any]], ready: [[String: Any]], serverNext: Double?, directory: URL, defaults: UserDefaults, lease: BloomSharedFileLock) throws {
        let lock = BloomSharedFileLock(directory.appendingPathComponent("carousel-state.lock"))
        guard lock.acquire() else { throw SyncError.busy }; defer { lock.release() }
        guard lease.isHeld(), valid(context, directory: directory, defaults: defaults) else { throw SyncError.superseded }
        let current = BloomSharedState.load() ?? [:]
        guard BloomSharedState.planId(current) <= ((plan["plan_id"] as? NSNumber)?.intValue ?? 0) else { throw SyncError.superseded }
        let merged = BloomSharedState.merging(current, plan: plan, grid: grid, ready: ready, nowMillis: Date().timeIntervalSince1970 * 1000, serverNext: serverNext)
        try publish(merged, directory: directory)
    }

    private func publish(_ state: [String: Any], directory: URL) throws {
        try BloomSharedState.writeJSON(state, to: directory.appendingPathComponent(BloomSharedState.fileName))
        var projection = BloomSharedState.readJSON(directory.appendingPathComponent("daily.json")) ?? [:]
        projection["mode"] = "carousel"; projection["pipeline"] = "carousel"
        projection["next_slot_at_ms"] = state["next_slot_at_ms"] ?? NSNull()
        projection["current_status"] = state["current_status"] ?? "pending"
        projection["next_slot_source"] = "plan"; projection["carousel_plan_id"] = BloomSharedState.planId(state)
        if let due = BloomCarouselRule.currentEntry(BloomSharedState.timelineEntries(state), nowMillis: Date().timeIntervalSince1970 * 1000) {
            projection["recommendation_id"] = due["item_id"]; projection["carousel_item_id"] = due["item_id"]
            for key in ["date", "caption_zh", "caption_en", "captured_date_text", "location_text", "source_name", "content_snapshot", "photo_metadata"] { projection[key] = due[key] ?? NSNull() }
        }
        try BloomSharedState.writeJSON(projection, to: directory.appendingPathComponent("daily.json"))
    }

    private func timelineEntry(_ item: [String: Any], directory: URL) -> [String: Any] {
        let id = item["item_id"] as! Int
        let caption = item["caption"] as? [String: Any] ?? [:]
        let formatter = DateFormatter(); formatter.dateFormat = "yyyy-MM-dd"; formatter.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return [
            "item_id": id, "asset_id": item["asset_id"] ?? "", "date_ms": Int(millis(item["display_at"])),
            "date": formatter.string(from: Date(timeIntervalSince1970: millis(item["display_at"]) / 1000)),
            "original_path": directory.appendingPathComponent("carousel-original-\(id).photo").path,
            "portrait_path": directory.appendingPathComponent("mobile-local-portrait-\(id).png").path,
            "square_path": directory.appendingPathComponent("mobile-local-square-\(id).png").path,
            "large_square_path": directory.appendingPathComponent("mobile-local-largeSquare-\(id).png").path,
            "caption_zh": caption["zh"] ?? NSNull(), "caption_en": caption["en"] ?? NSNull(),
            "captured_date_text": item["captured_date_text"] ?? NSNull(), "location_text": item["location_text"] ?? NSNull(),
            "source_name": item["source_name"] ?? "personal", "content_snapshot": item["content_snapshot"] ?? [:], "photo_metadata": item["photo"] ?? [:],
        ]
    }

    private func ready(_ item: [String: Any], directory: URL) -> Bool {
        guard let id = item["item_id"] as? Int else { return false }
        do {
            let marker = BloomSharedState.readJSON(directory.appendingPathComponent("mobile-original-\(id).json"))
            guard marker?["asset"] as? String == item["asset_id"] as? String,
                  marker?["source"] as? String == item["source_name"] as? String else { return false }
            let render = BloomSharedState.readJSON(directory.appendingPathComponent("mobile-render-\(id).json"))
            if render?["native_descriptor"] as? String != descriptorFingerprint(item) {
                let artwork = render?["artwork"] as? [String: Any] ?? [:]
                let expectedArtwork = item["content_snapshot"] as? [String: Any] ?? [:]
                let photo = item["photo"] as? [String: Any] ?? [:]
                let focuses = render?["photo"] as? [Any] ?? []
                let caption = item["caption"] as? [String: Any] ?? [:]
                let renderedCaption = render?["caption"] as? [Any] ?? []
                guard render?["asset"] as? String == item["asset_id"] as? String,
                      render?["source"] as? String == item["source_name"] as? String,
                      NSDictionary(dictionary: artwork).isEqual(to: expectedArtwork),
                      renderedCaption.count == 2,
                      NSArray(array: renderedCaption).isEqual(to: [caption["zh"] ?? NSNull(), caption["en"] ?? NSNull()]),
                      render?["captured"] as? String == item["captured_date_text"] as? String,
                      render?["location"] as? String == item["location_text"] as? String,
                      focuses.count == 2,
                      NSArray(array: focuses).isEqual(to: [photo["focus_x"] ?? NSNull(), photo["focus_y"] ?? NSNull()]) else { return false }
            }
        }
        let stem = "mobile-local"
        let names = ["carousel-original-\(id).photo"] + ["portrait", "square", "largeSquare"].map { "\(stem)-\($0)-\(id).png" }
        return names.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    private func descriptorFingerprint(_ item: [String: Any]) -> String {
        let descriptor: [String: Any] = ["asset": item["asset_id"] ?? "", "source": item["source_name"] ?? "personal",
            "photo": item["photo"] ?? [:], "artwork": item["content_snapshot"] ?? [:],
            "caption": item["caption"] ?? [:], "captured": item["captured_date_text"] ?? NSNull(), "location": item["location_text"] ?? NSNull()]
        let data = (try? JSONSerialization.data(withJSONObject: descriptor, options: [.sortedKeys, .withoutEscapingSlashes])) ?? Data()
        return Self.fingerprint(String(data: data, encoding: .utf8) ?? "")
    }

    private func prune(directory: URL) {
        let state = BloomSharedState.load() ?? [:]
        let entries = BloomSharedState.timelineEntries(state)
        var alive = Set(entries.compactMap { ($0["item_id"] as? NSNumber)?.intValue })
        for key in ["current_item_id", "previous_item_id"] { if let id = state[key] as? Int { alive.insert(id) } }
        let dailyID = BloomSharedState.readJSON(directory.appendingPathComponent("daily.json"))?["recommendation_id"] as? Int
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dailyOriginals = files.filter { $0.lastPathComponent.range(of: "^daily-original-[0-9]+\\.photo$", options: .regularExpression) != nil }
            .sorted {
                let left = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                let right = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                return left > right
            }
        func photoID(_ name: String) -> Int? {
            Int(name.replacingOccurrences(of: "^.*-([0-9]+)\\.[^.]+$", with: "$1", options: .regularExpression))
        }
        var keepDaily = Set(dailyOriginals.prefix(2).compactMap { photoID($0.lastPathComponent) })
        let projection = BloomSharedState.readJSON(directory.appendingPathComponent("daily.json"))
        if projection?["pipeline"] as? String != "daily" { keepDaily.removeAll() }
        if projection?["pipeline"] as? String == "daily", let dailyID { keepDaily.insert(dailyID) }
        if let defaults = UserDefaults(suiteName: BloomSharedState.appGroup) {
            for key in ["portraitPath", "squarePath", "largeSquarePath"] {
                if let path = defaults.string(forKey: key), path.contains("mobile-daily-"), let id = photoID(URL(fileURLWithPath: path).lastPathComponent) { keepDaily.insert(id) }
            }
        }
        for file in files where file.lastPathComponent.range(of: "^(?:daily-original-|mobile-daily-[A-Za-z]+-)[0-9]+\\.(?:photo|png)$", options: .regularExpression) != nil {
            if let id = photoID(file.lastPathComponent), !keepDaily.contains(id),
               let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date().timeIntervalSince(date) > 120 { try? FileManager.default.removeItem(at: file) }
        }
        for file in files {
            let name = file.lastPathComponent
            guard let range = name.range(of: "^(?:carousel-original-|mobile-local-[A-Za-z]+-|mobile-(?:original|render)-)([0-9]+)\\.(?:photo|png|json)$", options: .regularExpression), range == name.startIndex..<name.endIndex else { continue }
            let digits = name.replacingOccurrences(of: "^.*-([0-9]+)\\.[^.]+$", with: "$1", options: .regularExpression)
            guard let id = Int(digits), !alive.contains(id),
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  Date().timeIntervalSince(modified) > 120 else { continue }
            let photoLock = BloomSharedFileLock(directory.appendingPathComponent("photo-prepare-\(id).lock"))
            guard photoLock.acquire() else { continue }
            defer { photoLock.release() }
            try? FileManager.default.removeItem(at: file)
        }
        // Remove abandoned staging bytes only after a day; active background
        // transfers and just-completed publications must remain untouched.
        for file in files where file.lastPathComponent.hasPrefix("widget-refill-") || file.lastPathComponent.hasPrefix("widget-render-") {
            if let date = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, Date().timeIntervalSince(date) > 86400 { try? FileManager.default.removeItem(at: file) }
        }
    }

    private func devicePath(_ device: String, _ endpoint: String) -> String { "/api/frame/devices/\(device.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? device)/\(endpoint)" }
    private func request(path: String, token: String, body: [String: Any]?) throws -> URLRequest {
        guard let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host == base.host, url.scheme == "https" else { throw SyncError.url }
        var value = URLRequest(url: url); value.httpMethod = body == nil ? "GET" : "POST"
        value.timeoutInterval = 8; value.setValue(token, forHTTPHeaderField: "X-Frame-Token")
        if let body { value.setValue("application/json", forHTTPHeaderField: "Content-Type"); value.httpBody = try JSONSerialization.data(withJSONObject: body) }
        return value
    }
    private func millis(_ value: Any?) -> Double {
        guard let string = value as? String else { return 0 }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return ((formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string))?.timeIntervalSince1970 ?? 0) * 1000
    }
    private func log(_ text: String) {
        guard let directory = BloomSharedState.cacheDirectory() else { return }
        let file = directory.appendingPathComponent("widget-refill.log")
        let line = Data("\(ISO8601DateFormatter().string(from: Date())) \(text)\n".utf8)
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 64 * 1024 { try? FileManager.default.removeItem(at: file) }
        if let handle = try? FileHandle(forWritingTo: file) { handle.seekToEndOfFile(); handle.write(line); try? handle.close() }
        else { try? line.write(to: file, options: .atomic) }
    }
    private enum SyncError: LocalizedError {
        case busy, superseded, image, url, json, http(Int)
        var errorDescription: String? {
            switch self {
            case .busy: return "shared cache writer busy"
            case .superseded: return "settings or plan superseded"
            case .image: return "image decode or publication failed"
            case .url: return "invalid photo URL"
            case .json: return "invalid metadata JSON"
            case .http(let status): return "HTTP \(status)"
            }
        }
    }
}
