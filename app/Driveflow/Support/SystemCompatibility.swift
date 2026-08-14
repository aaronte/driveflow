import Foundation

/// What kind of Mac Driveflow is actually running on.
///
/// The shipped binary is arm64-only with `LSMinimumSystemVersion` 14.0, so an
/// unsupported Mac usually can't launch the app at all. The checks still matter
/// for Rosetta translation, and they keep working if the build ever goes
/// universal or drops its minimum OS.
struct SystemCompatibility {
    static let minimumMajorOS = 14

    let chipName: String?
    let isAppleSilicon: Bool
    /// True when an arm64 build is being emulated on Intel via Rosetta.
    let isTranslated: Bool
    let osVersion: OperatingSystemVersion

    static func current() -> SystemCompatibility {
        SystemCompatibility(
            chipName: sysctlString("machdep.cpu.brand_string"),
            isAppleSilicon: sysctlInt("hw.optional.arm64") == 1,
            isTranslated: sysctlInt("sysctl.proc_translated") == 1,
            osVersion: ProcessInfo.processInfo.operatingSystemVersion
        )
    }

    var meetsOSMinimum: Bool {
        osVersion.majorVersion >= Self.minimumMajorOS
    }

    var isSupported: Bool {
        isAppleSilicon && !isTranslated && meetsOSMinimum
    }

    /// Short readout for the supported case, e.g. `Apple M3 Pro · macOS 15.1`.
    var summary: String {
        "\(chipName ?? (isAppleSilicon ? "Apple Silicon" : "Intel")) · macOS \(osDescription)"
    }

    /// Why this Mac falls short, or `nil` when everything checks out.
    var issue: String? {
        if isTranslated {
            return "Running under Rosetta — open the Apple Silicon build"
        }
        if !isAppleSilicon {
            return "Intel Mac — Driveflow needs Apple Silicon"
        }
        if !meetsOSMinimum {
            return "macOS \(osDescription) — Driveflow needs 14 or later"
        }
        return nil
    }

    private var osDescription: String {
        osVersion.patchVersion > 0
            ? "\(osVersion.majorVersion).\(osVersion.minorVersion).\(osVersion.patchVersion)"
            : "\(osVersion.majorVersion).\(osVersion.minorVersion)"
    }

    // MARK: - sysctl

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        let value = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }
}
