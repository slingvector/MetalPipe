//
//  MemoryGuard.swift
//  BroadcastExtension
//
//  Broadcast upload extensions are silently killed by jetsam around
//  ~50MB phys_footprint. This is almost certainly why the old project
//  "worked 2-3 times then got stuck" — there is no crash dialog, no
//  log, the extension just stops being scheduled.
//
//  We read phys_footprint directly and shed work BEFORE the limit.
//

import Foundation

enum MemoryGuard {

    /// Current physical memory footprint in MB (the number jetsam uses).
    static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) { infoPtr in
            infoPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), intPtr, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1_048_576
    }

    enum Pressure { case ok, soft, hard }

    static func pressure() -> Pressure {
        let mb = footprintMB()
        if mb >= MetalPipeConfig.memoryHardLimitMB { return .hard }
        if mb >= MetalPipeConfig.memorySoftLimitMB { return .soft }
        return .ok
    }
}
