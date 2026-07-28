import Foundation
import IOKit
import IOKit.usb

/// IOKit service matching for RTL2832U-based SDR dongles (e.g. NESDR).
///
/// The RTL2832U demodulator enumerates on USB with Realtek's vendor ID and the
/// generic `0x2838` product ID that virtually all bare RTL-SDR dongles ship with.
enum USBDeviceMatching {
    /// Realtek Semiconductor USB vendor ID.
    static let rtlVendorID: Int = 0x0bda
    /// RTL2832U generic product ID used by RTL-SDR dongles.
    static let rtlProductID: Int = 0x2838

    /// Returns the `io_service_t` handles for every currently-attached device that
    /// matches the RTL VID/PID.
    ///
    /// Ownership: each returned service carries a retain (they come from
    /// `IOIteratorNext`). The **caller owns** these references and must balance each
    /// one with `IOObjectRelease` once finished (or hand it to
    /// `IOUSBHostTransport(service:)`, which retains its own reference internally).
    /// The iterator created here is released before returning.
    static func matchingRTLServices() -> [io_service_t] {
        // `kIOUSBHostDeviceClassName` / `kUSBVendorID` / `kUSBProductID` are chained C
        // `#define` macros that do not import into Swift as usable constants, so we use
        // their documented literal values ("IOUSBHostDevice", "idVendor", "idProduct").
        guard let matching = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary? else {
            return []
        }
        matching["idVendor"] = rtlVendorID
        matching["idProduct"] = rtlProductID

        var iterator: io_iterator_t = IO_OBJECT_NULL
        // IOServiceGetMatchingServices consumes one reference to the matching dictionary.
        let result = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard result == KERN_SUCCESS, iterator != IO_OBJECT_NULL else {
            return []
        }
        defer { IOObjectRelease(iterator) }

        var services: [io_service_t] = []
        var service = IOIteratorNext(iterator)
        while service != IO_OBJECT_NULL {
            services.append(service)
            service = IOIteratorNext(iterator)
        }
        return services
    }
}
