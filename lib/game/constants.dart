const int kCols = 8;
const int kRows = 16;

const int kBlockCount = 8;

const List<int> kBlockIndices = [1, 2, 3, 4, 5, 6, 8];

String blockAssetPath(int index) => 'assets/gameplay/${index}_block_asset.webp';

const String kBgAsset = 'assets/gameplay/bg_asset.webp';
const String kBaseAsset = 'assets/gameplay/base_asset.webp';
const String kGridAsset = 'assets/gameplay/grid_asset.webp';
const String kLeftWallAsset = 'assets/gameplay/left_wall_asset.webp';
const String kRightWallAsset = 'assets/gameplay/right_wall_asset.webp';

const String kLogoAsset = 'assets/logo/logo.webp';
const String kLogoNameAsset = 'assets/logo/logo_name.webp';

const String kLoadingVideoPortrait = 'assets/loading/9x16_loading_screen.mp4';
const String kLoadingVideoLandscape = 'assets/loading/16x9_loading_screen.mp4';

const String kEmptyBarAsset = 'assets/loading/empty_bar.webp';
const String kAlmostBarAsset = 'assets/loading/almost_bar.webp';
const String kFullBarAsset = 'assets/loading/full_bar.webp';

const Duration kLoadingMinDuration = Duration(milliseconds: 3200);

const String kBestScoreKey = 'tower_falls.best_score';

const String kPrivacyPolicyUrl = 'https://towerrfalls.com/privacy-policy.html';
const String kSupportUrl = 'https://towerrfalls.com/support.html';
