import Foundation
import Darwin

/// Which processes belong to which app. Used by the nap engine in every build.
enum ProcessTable {
    /// pid → the process macOS holds responsible for it (XPC services such as Safari's WebKit processes are not
    /// children of the app, but macOS attributes them to it). One call per process, so the result is shared for a
    /// few seconds instead of being rebuilt by each caller.
    private static var responsibleCache: (time: Date, map: [pid_t: pid_t])?

    static func responsibleMap() -> [pid_t: pid_t] {
        if let c = responsibleCache, Date().timeIntervalSince(c.time) < 8 { return c.map }
        var map: [pid_t: pid_t] = [:]
        if let responsible = NapEngine.responsibleFn {
            let count = Int(proc_listallpids(nil, 0))
            if count > 0 {
                var all = [pid_t](repeating: 0, count: count + 64)
                let n = Int(proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size)))
                for pid in all.prefix(max(n, 0)) where pid > 1 { map[pid] = responsible(pid) }
            }
        }
        responsibleCache = (Date(), map)
        return map
    }

    /// Every process that belongs to one of the apps: the app, its children, and processes macOS attributes to it.
    static func members(of roots: [pid_t]) -> [pid_t: pid_t] {
        var owner: [pid_t: pid_t] = [:]
        for r in roots {
            owner[r] = r
            var queue = [r]
            while let p = queue.popLast() {
                var buf = [pid_t](repeating: 0, count: 256)
                let bytes = proc_listchildpids(p, &buf, Int32(buf.count * MemoryLayout<pid_t>.size))
                guard bytes > 0 else { continue }
                for kid in buf.prefix(Int(bytes) / MemoryLayout<pid_t>.size) where kid > 0 && owner[kid] == nil {
                    owner[kid] = r; queue.append(kid)
                }
            }
        }
        let rootSet = Set(roots)
        for (pid, r) in responsibleMap() where owner[pid] == nil && rootSet.contains(r) { owner[pid] = r }
        return owner
    }

}
