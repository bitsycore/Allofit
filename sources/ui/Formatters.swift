import Foundation

// Formatters bundles the byte-count and date formatting used by both
// the Table's columns and the right-hand preview pane footer. Keeping
// the formatter instances cached at file scope avoids reconstructing
// them per row render, which would be expensive at thousands of rows.
enum Formatters {

	// file-size formatter (decimal units, like Finder)
	private static let kSizeFormatter: ByteCountFormatter = {
		let vF = ByteCountFormatter()
		vF.countStyle = .file
		return vF
	}()

	// human-friendly byte count, e.g. "1.2 MB"
	static func size(bytes inBytes: Int64) -> String {
		return kSizeFormatter.string(fromByteCount: inBytes)
	}

	// memory formatter (binary units, like Activity Monitor)
	private static let kMemoryFormatter: ByteCountFormatter = {
		let vF = ByteCountFormatter()
		vF.countStyle = .memory
		return vF
	}()

	// memory amount, e.g. "312 MB" (binary units, like Activity Monitor)
	static func memory(bytes inBytes: UInt64) -> String {
		return kMemoryFormatter.string(fromByteCount: Int64(clamping: inBytes))
	}

	// same as size(bytes:), but "-" for zero / unknown (missing files)
	static func sizeOrDash(bytes inBytes: Int64) -> String {
		return inBytes <= 0 ? "-" : size(bytes: inBytes)
	}

	// short date + short time, in the user's locale
	private static let kDateFormatter: DateFormatter = {
		let vF = DateFormatter()
		vF.dateStyle = .short
		vF.timeStyle = .short
		return vF
	}()

	// short date+time, with "-" for sentinel "no date" values
	static func date(_ inDate: Date) -> String {
		if inDate.timeIntervalSince1970 < 1 { return "-" }
		return kDateFormatter.string(from: inDate)
	}
}
