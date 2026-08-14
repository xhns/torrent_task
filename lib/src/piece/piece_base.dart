export 'piece_manager.dart';
export 'piece_provider.dart';
export 'piece.dart';
export 'piece_selector.dart';
export 'sequential_piece_selector.dart';
// base_piece_selector.dart НАМЕРЕННО не реэкспортируется: тесты движка берут
// его прямым импортом из src, а публичной точкой выбора стратегии служит
// createPieceSelector (piece_selector.dart).
