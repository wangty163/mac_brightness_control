import Foundation

public enum SystemProfilerParser {
    public static func parseDisplays(from jsonText: String) throws -> [DisplayInfo] {
        let data = Data(jsonText.utf8)
        let payload = try JSONDecoder().decode(SystemProfilerPayload.self, from: data)
        return payload.SPDisplaysDataType.flatMap { gpu in
            (gpu.spdisplaysNdrvs ?? []).compactMap { raw in
                guard !raw.isVirtual else { return nil }
                let connection = raw.connectionType
                return DisplayInfo(
                    displayID: parseDisplayID(raw.displayID),
                    name: raw.name ?? "Unknown Display",
                    kind: connection == "spdisplays_internal" ? .internal : .external,
                    online: raw.online == "spdisplays_yes",
                    resolution: raw.resolution,
                    connectionType: connection
                )
            }
        }
    }

    private static func parseDisplayID(_ raw: String?) -> UInt32? {
        guard let raw, !raw.isEmpty else { return nil }
        if raw.hasPrefix("0x") || raw.hasPrefix("0X") {
            return UInt32(raw.dropFirst(2), radix: 16)
        }
        return UInt32(raw, radix: 16)
    }
}

private struct SystemProfilerPayload: Decodable {
    let SPDisplaysDataType: [GPUDisplays]
}

private struct GPUDisplays: Decodable {
    let spdisplaysNdrvs: [RawDisplay]?

    enum CodingKeys: String, CodingKey {
        case spdisplaysNdrvs = "spdisplays_ndrvs"
    }
}

private struct RawDisplay: Decodable {
    let name: String?
    let displayID: String?
    let resolution: String?
    let connectionType: String?
    let online: String?
    let productID: String?
    let vendorID: String?

    var isVirtual: Bool {
        productID == "76697274" && vendorID == "756e6b6e"
    }

    enum CodingKeys: String, CodingKey {
        case name = "_name"
        case displayID = "_spdisplays_displayID"
        case resolution = "_spdisplays_resolution"
        case connectionType = "spdisplays_connection_type"
        case online = "spdisplays_online"
        case productID = "_spdisplays_display-product-id"
        case vendorID = "_spdisplays_display-vendor-id"
    }
}
