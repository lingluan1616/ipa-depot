import Foundation
import Compression

/// 极简 ZIP 读取器：只读中央目录与单个条目（stored / deflate），支持 ZIP64。用于校验下载的 IPA。
public struct ZipReader {
    public struct Entry: Sendable, Equatable {
        public let name: String
        public let method: UInt16
        public let compressedSize: UInt64
        public let uncompressedSize: UInt64
        public let localHeaderOffset: UInt64
    }

    public let url: URL
    public let entries: [Entry]
    private let handle: FileHandle
    private let fileSize: UInt64

    public init(url: URL) throws {
        self.url = url
        handle = try FileHandle(forReadingFrom: url)
        fileSize = try handle.seekToEnd()
        entries = try Self.readCentralDirectory(handle: handle, fileSize: fileSize)
    }

    public func close() { try? handle.close() }

    public func entry(named name: String) -> Entry? { entries.first { $0.name == name } }

    public func data(for entry: Entry, maxSize: UInt64 = 64 * 1024 * 1024) throws -> Data {
        guard entry.uncompressedSize <= maxSize else { throw Self.error("entry too large: \(entry.name)") }
        let local = try read(at: entry.localHeaderOffset, count: 30)
        guard local.u32(0) == 0x04034b50 else { throw Self.error("bad local header") }
        let nameLen = UInt64(local.u16(26)), extraLen = UInt64(local.u16(28))
        let dataOffset = entry.localHeaderOffset + 30 + nameLen + extraLen
        let compressed = try read(at: dataOffset, count: Int(entry.compressedSize))
        switch entry.method {
        case 0:
            return compressed
        case 8:
            return try Self.inflate(compressed, expectedSize: Int(entry.uncompressedSize))
        default:
            throw Self.error("unsupported compression method \(entry.method)")
        }
    }

    // MARK: - 内部

    private func read(at offset: UInt64, count: Int) throws -> Data {
        guard offset + UInt64(count) <= fileSize else { throw Self.error("read beyond end of file") }
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: count) ?? Data()
        guard data.count == count else { throw Self.error("short read") }
        return data
    }

    private static func readCentralDirectory(handle: FileHandle, fileSize: UInt64) throws -> [Entry] {
        guard fileSize >= 22 else { throw error("file too small") }
        let tailSize = min(fileSize, 65_535 + 22)
        try handle.seek(toOffset: fileSize - tailSize)
        let tail = try handle.read(upToCount: Int(tailSize)) ?? Data()
        var eocd: Int?
        var i = tail.count - 22
        while i >= 0 {
            if tail.u32(i) == 0x06054b50 { eocd = i; break }
            i -= 1
        }
        guard let eocd else { throw error("end of central directory not found") }
        var count = UInt64(tail.u16(eocd + 10))
        var cdSize = UInt64(tail.u32(eocd + 12))
        var cdOffset = UInt64(tail.u32(eocd + 16))

        // ZIP64
        if count == 0xFFFF || cdSize == 0xFFFF_FFFF || cdOffset == 0xFFFF_FFFF, eocd >= 20,
           tail.u32(eocd - 20) == 0x07064b50 {
            let z64Offset = tail.u64(eocd - 20 + 8)
            try handle.seek(toOffset: z64Offset)
            let z = try handle.read(upToCount: 56) ?? Data()
            guard z.count == 56, z.u32(0) == 0x06064b50 else { throw error("bad zip64 end record") }
            count = z.u64(32)
            cdSize = z.u64(40)
            cdOffset = z.u64(48)
        }
        guard cdOffset + cdSize <= fileSize, cdSize < 512 * 1024 * 1024 else { throw error("bad central directory") }
        try handle.seek(toOffset: cdOffset)
        let cd = try handle.read(upToCount: Int(cdSize)) ?? Data()
        guard cd.count == Int(cdSize) else { throw error("short central directory") }

        var entries: [Entry] = []
        entries.reserveCapacity(Int(min(count, 1_000_000)))
        var p = 0
        while p + 46 <= cd.count, cd.u32(p) == 0x02014b50 {
            let method = cd.u16(p + 10)
            var compressed = UInt64(cd.u32(p + 20))
            var uncompressed = UInt64(cd.u32(p + 24))
            let nameLen = Int(cd.u16(p + 28)), extraLen = Int(cd.u16(p + 30)), commentLen = Int(cd.u16(p + 32))
            var localOffset = UInt64(cd.u32(p + 42))
            guard p + 46 + nameLen + extraLen + commentLen <= cd.count else { throw error("truncated entry") }
            let name = String(decoding: cd[(cd.startIndex + p + 46)..<(cd.startIndex + p + 46 + nameLen)], as: UTF8.self)
            // ZIP64 扩展字段
            var e = p + 46 + nameLen
            let extraEnd = e + extraLen
            while e + 4 <= extraEnd {
                let id = cd.u16(e), size = Int(cd.u16(e + 2))
                if id == 0x0001 {
                    var q = e + 4
                    if uncompressed == 0xFFFF_FFFF, q + 8 <= e + 4 + size { uncompressed = cd.u64(q); q += 8 }
                    if compressed == 0xFFFF_FFFF, q + 8 <= e + 4 + size { compressed = cd.u64(q); q += 8 }
                    if localOffset == 0xFFFF_FFFF, q + 8 <= e + 4 + size { localOffset = cd.u64(q); q += 8 }
                }
                e += 4 + size
            }
            entries.append(Entry(name: name, method: method, compressedSize: compressed,
                                 uncompressedSize: uncompressed, localHeaderOffset: localOffset))
            p += 46 + nameLen + extraLen + commentLen
        }
        return entries
    }

    static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, expectedSize,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw error("inflate failed") }
        return output
    }

    static func error(_ text: String) -> IpatoolError {
        IpatoolError(kind: .verificationFailed, raw: "zip: \(text)")
    }
}

extension Data {
    func u16(_ i: Int) -> UInt16 {
        let b = startIndex + i
        return UInt16(self[b]) | UInt16(self[b + 1]) << 8
    }
    func u32(_ i: Int) -> UInt32 {
        UInt32(u16(i)) | UInt32(u16(i + 2)) << 16
    }
    func u64(_ i: Int) -> UInt64 {
        UInt64(u32(i)) | UInt64(u32(i + 4)) << 32
    }
}

/// IPA 包信息（来自 `Payload/*.app/Info.plist`）。
public struct IPAInfo: Sendable, Equatable {
    public let bundleIdentifier: String
    public let shortVersion: String?
    public let bundleVersion: String?
    public let appName: String

    /// 打开 IPA（zip），读取主 App 的 Info.plist。不是有效 IPA 时抛 `.verificationFailed`。
    public static func read(from url: URL) throws -> IPAInfo {
        let zip = try ZipReader(url: url)
        defer { zip.close() }
        let pattern = try NSRegularExpression(pattern: #"^Payload/([^/]+)\.app/Info\.plist$"#)
        guard let entry = zip.entries.first(where: {
            pattern.firstMatch(in: $0.name, range: NSRange(location: 0, length: ($0.name as NSString).length)) != nil
        }) else {
            throw ZipReader.error("Payload/*.app/Info.plist not found")
        }
        let data = try zip.data(for: entry)
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String else {
            throw ZipReader.error("invalid Info.plist")
        }
        let appName = String(entry.name.dropFirst("Payload/".count).dropLast(".app/Info.plist".count))
        return IPAInfo(bundleIdentifier: bundleID,
                       shortVersion: plist["CFBundleShortVersionString"] as? String,
                       bundleVersion: plist["CFBundleVersion"] as? String,
                       appName: appName)
    }
}
