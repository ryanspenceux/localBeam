import Foundation

struct TransferInfo {
    let filename: String
    let fileSize: UInt64
    let fileURL: URL?          // only set on sender side

    var headerData: Data {
        let filenameData = filename.data(using: .utf8)!
        var headerLength = UInt32(filenameData.count).bigEndian
        var size = fileSize.bigEndian

        var header = Data()
        header.append(Data(bytes: &headerLength, count: 4))
        header.append(filenameData)
        header.append(Data(bytes: &size, count: 8))
        return header
    }

    static func parse(from data: Data) -> (info: TransferInfo, bytesConsumed: Int)? {
        guard data.count >= 4 else { return nil }

        let filenameLength = Int(data.withUnsafeBytes {
            $0.load(fromByteOffset: 0, as: UInt32.self).bigEndian
        })

        let headerSize = 4 + filenameLength + 8
        guard data.count >= headerSize else { return nil }

        let filenameData = data[4 ..< 4 + filenameLength]
        let filename = String(data: filenameData, encoding: .utf8) ?? "unknown"

        let fileSize = data.withUnsafeBytes {
            $0.load(fromByteOffset: 4 + filenameLength, as: UInt64.self).bigEndian
        }

        let info = TransferInfo(filename: filename, fileSize: fileSize, fileURL: nil)
        return (info, headerSize)
    }
}
