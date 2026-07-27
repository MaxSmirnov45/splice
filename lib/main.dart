import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'src/core/save.dart';
import 'src/ui/ability_card.dart';
import 'src/ui/game_screen.dart';
import 'src/ui/title_screen.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // A one-thumb action game wants the whole screen and a single orientation.
  await SystemChrome.setPreferredOrientations([
    DeviceOrientation.portraitUp,
    DeviceOrientation.portraitDown,
  ]);
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

  runApp(SpliceApp(save: await SaveData.load()));
}

class SpliceApp extends StatelessWidget {
  final SaveData save;

  const SpliceApp({super.key, required this.save});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SPLICE',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: Skin.bg,
      ),
      home: RootScreen(save: save),
    );
  }
}

/// Switches between the title screen and a run.
///
/// The game is torn down when returning to the title rather than kept warm:
/// a finished run holds several hundred pooled entities, and the title screen
/// has no reason to keep them alive.
class RootScreen extends StatefulWidget {
  final SaveData save;

  const RootScreen({super.key, required this.save});

  @override
  State<RootScreen> createState() => _RootScreenState();
}

class _RootScreenState extends State<RootScreen> {
  /// Skips the title screen when capturing screenshots. Const from the
  /// environment, so it costs nothing in a normal build.
  static const bool _autoStart = bool.fromEnvironment('SPLICE_DEMO');

  bool _playing = _autoStart;

  /// Bumped on each new run so Flutter builds a fresh game rather than
  /// reusing the previous run's state.
  int _runKey = 0;

  @override
  Widget build(BuildContext context) {
    if (!_playing) {
      return TitleScreen(
        save: widget.save,
        onPlay: () => setState(() {
          _playing = true;
          _runKey++;
        }),
      );
    }
    return GameScreen(
      key: ValueKey(_runKey),
      save: widget.save,
      onExit: () => setState(() => _playing = false),
    );
  }
}
