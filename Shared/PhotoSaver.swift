import Foundation
import Photos

enum PhotoSaver {

    /// 「追加のみ」の写真ライブラリ権限を確認・リクエストする
    static func ensurePermission() async throws {
        let current = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch current {
        case .authorized, .limited:
            return
        case .notDetermined:
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard status == .authorized || status == .limited else {
                throw SaveError.photoPermissionDenied
            }
        default:
            throw SaveError.photoPermissionDenied
        }
    }

    /// ダウンロード済みファイルを写真ライブラリに保存する(ファイルは移動され、元の場所からは消える)
    static func save(fileURL: URL, type: MediaType) async throws {
        try await PHPhotoLibrary.shared().performChanges {
            let request = PHAssetCreationRequest.forAsset()
            let options = PHAssetResourceCreationOptions()
            options.shouldMoveFile = true
            request.addResource(
                with: type == .photo ? .photo : .video,
                fileURL: fileURL,
                options: options
            )
        }
    }
}
