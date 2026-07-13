import CoreGraphics
import Foundation

#if canImport(Metal) && canImport(MetalKit)
extension MosaicRenderer {
    /// 顔ごとの描画オプション（リアルタイム撮影の速度適応マージン用）。
    /// `render(landmarkSets:faceOptions:)` に `landmarkSets` と添字対応で渡す。
    public struct FaceRenderOption: Sendable {
        /// 凸包マスクの膨らみ（nil = ビルダー既定）。速い顔ほど広げて
        /// 位置ラグによる露出を防ぐ。
        public let dilation: CGFloat?
        /// フルメッシュ顔でも凸包マスクで描く。メッシュ経路は余白ゼロのため、
        /// フロー外挿中（位置が推定値）の顔は余白のある凸包に降格して安全側に倒す。
        public let forceConvexHull: Bool

        public init(dilation: CGFloat? = nil, forceConvexHull: Bool = false) {
            self.dilation = dilation
            self.forceConvexHull = forceConvexHull
        }
    }

    /// 顔をメッシュ経路と凸包（コンタマスク）経路に振り分ける。
    /// `forceConvexHull` の顔はフルメッシュでも凸包へ降格し、per-face dilation を添える。
    func partitionFaces(
        _ landmarkSets: [FaceLandmarkSet],
        options: [FaceRenderOption]?
    ) -> (fullMesh: [FaceLandmarkSet],
          partial: [(landmarks: FaceLandmarkSet, dilation: CGFloat?)]) {
        func option(at index: Int) -> FaceRenderOption? {
            guard let options, options.indices.contains(index) else { return nil }
            return options[index]
        }
        var fullMesh: [FaceLandmarkSet] = []
        var partial: [(landmarks: FaceLandmarkSet, dilation: CGFloat?)] = []
        for index in landmarkSets.indices {
            let face = landmarkSets[index]
            if face.isFullMesh, !(option(at: index)?.forceConvexHull ?? false) {
                fullMesh.append(face)
            } else {
                partial.append((landmarks: face, dilation: option(at: index)?.dilation))
            }
        }
        return (fullMesh, partial)
    }
}
#endif
