import Foundation

/// The running processes, read from the kernel (no `ps` to spawn).
enum ProcessTable {
    /// Whether any process the user can see has a name that satisfies `predicate`.
    /// Nil if the list couldn't be read.
    static func contains(named predicate: (String) -> Bool) -> Bool? {
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return nil }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return nil }

        var name = [CChar](repeating: 0, count: 64)
        for pid in pids.prefix(count) where pid > 0 {
            guard proc_name(pid, &name, UInt32(name.count)) > 0 else { continue }
            if predicate(String(cString: name)) { return true }
        }
        return false
    }
}
