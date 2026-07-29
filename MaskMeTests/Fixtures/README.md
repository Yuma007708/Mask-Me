# テストフィクスチャ（実素材での検出・モザイク検証）

ここに置いた**実素材**に対して MediaPipe Face Landmarker と Metal モザイクを実際に走らせ、
検出率・誤検出率・ランドマーク妥当性・モザイクの焼き込みを検証します。

プライバシー・著作権の都合で**素材はリポジトリに含めていません**（`.gitignore` でこの
README と `.gitkeep` 以外を除外）。各自で用意して以下の構成で配置してください。
ファイルが無い場合、該当テストは失敗ではなく `XCTSkip`（スキップ）になります。

素材は自前のものでも、Pexels / Pixabay などの**ライセンスフリーのストック素材**でも
構いません（リポジトリに入らないので配布の問題は起きません）。

## 配置

```
MaskMeTests/Fixtures/
├─ face_landmarker.task     # MediaPipe モデル（アプリと共用可。テストにも必要）
├─ faces/                   # 顔が写っている画像（jpg/jpeg/png/heic）
│  ├─ face_01.jpg
│  └─ ...
├─ nonfaces/                # 顔が写っていない画像（風景・建物・室内など）
│  ├─ scene_01.jpg
│  └─ ...
├─ sample_face.mov          # 顔が映る短い動画（数秒で可）
├─ profile.mov              # 正面 → 横顔まで首が回る動画（3D warp 経路の検証用）
└─ probe/                   # 診断用（任意）。動画 .mov と静止画 .jpg を混在で置ける
   ├─ probe_*.mov
   └─ *.jpg
```

`probe/` は合否を判定しない診断テスト（`RealFaceMosaicTests`）が走査し、何を顔として
検出したかをログと注釈つき PNG に出します。難しい条件（暗所・逆光・遮蔽・群衆・
顔に見えるが顔でないもの）を放り込んで挙動を見るための場所です。

## しきい値（テスト内で定義）

- `faces/`：検出率 **≥ 90%**（`DetectionAccuracyTests`）
- `nonfaces/`：誤検出率 **≤ 10%**（同上）
- `sample_face.mov`：フレーム検出率 **≥ 80%** かつ追従が `.tracking` にロック
  （`VideoDetectionTests`）
- `profile.mov`：適用区間内の顔領域が区間外の **0.6 倍未満**に平坦化されること
  （`RealFaceMosaicTests`）

しきい値は各テストの定数で調整できます。

## 素材選びの注意（実測にもとづく）

閾値を満たすかどうかは**素材の選び方に強く依存**します。実測で分かっていること:

- `faces/` に**引きの画（顔が画面の 1/10 以下）や完全な横顔**を入れると 90% を割ります。
  正面〜やや斜めの、顔がはっきり写ったものを使ってください。口元だけのクローズアップは
  顔として検出されません。
- `nonfaces/` に**手・食べ物・動物・彫像**を入れると 10% を超えます。実測では手 2/4、
  ハンバーガー 2/3、猿・石像・仮面も顔と判定されました。**風景・建物**を使ってください。
- 室内写真も安全ではありません。実測では**壁に掛かった飾り皿 2 枚とプランターを
  「両目と口」と見て顔と判定**しました（`probe/living_room.jpg` に診断素材として置いて
  あります）。誤検出には 2 種類あり、性質が違います:
  - **配置型**（飾り皿・彫像・仮面・猿）: 目鼻口の配置が実際に顔に似ている。人間の目にも
    顔に見えるもので、幾何フィルタでは原理的に切りにくい。
  - **テクスチャ型**（砂・波紋）: 自己相似なので、`verifySuspiciousFaces` の
    「切り出して再検出できるか」という検証をすり抜ける。実測で波打ち際の砂を検出。
  合否素材（`nonfaces/`）には前者を入れないでください。**診断したいものは `probe/` へ。**
- モデルは `MaskMe/face_landmarker.task` をコピーすれば流用できます。

## 実行方法

```bash
xcodegen generate    # ⚠️ 実行したら必ず pod install も走らせること
pod install
xcodebuild test \
  -workspace MaskMe.xcworkspace \
  -scheme MaskMe \
  -destination 'platform=iOS Simulator,name=iPhone 17'
```

または Xcode で `MaskMe.xcworkspace` を開き **Cmd+U**。

`Fixtures` はフォルダ参照としてテストバンドルに丸ごとコピーされるので、ファイルを
置くだけで拾われます（pbxproj への個別登録は不要）。

> 注: これらのテストは MediaPipe pod・モデル・実素材・Simulator が必要なため、
> pod 無しの CI（`build-app`）では実行しません。検出率の集計ロジック
> （`DetectionRateMeter`）は MosaicCore 側で `swift test` により CI で検証されます。
