import 'package:flutter/material.dart';

import '../core/leaderboard.dart';
import 'ability_card.dart';

/// Global scoreboard, ranked by survival time.
///
/// Fetches on open rather than caching: a board that shows stale positions is
/// worse than one that takes a moment, and a run ends rarely enough that the
/// request cost is irrelevant.
class LeaderboardScreen extends StatefulWidget {
  final Leaderboard leaderboard;
  final VoidCallback onClose;

  /// The run just finished, highlighted in the list if it placed.
  final ScoreEntry? highlight;

  const LeaderboardScreen({
    super.key,
    required this.leaderboard,
    required this.onClose,
    this.highlight,
  });

  @override
  State<LeaderboardScreen> createState() => _LeaderboardScreenState();
}

class _LeaderboardScreenState extends State<LeaderboardScreen> {
  List<ScoreEntry>? _entries;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _entries = null;
      _failed = false;
    });
    final rows = await widget.leaderboard.top();
    if (!mounted) return;
    setState(() {
      _entries = rows;
      // An empty board is ambiguous: nobody has played, or the request
      // failed. Only treat it as failure when the backend claims to work.
      _failed = rows.isEmpty && widget.leaderboard.isAvailable;
    });
  }

  static String _clock(double seconds) {
    final m = (seconds ~/ 60).toString().padLeft(2, '0');
    final s = (seconds % 60).floor().toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Skin.bg.withValues(alpha: 0.97),
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 10),
              child: Row(
                children: [
                  Text(
                    'LEADERBOARD',
                    style: Skin.label(
                      size: 18,
                      color: Skin.text,
                      weight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: widget.onClose,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(9),
                        border: Border.all(color: Skin.line),
                      ),
                      child: Text('CLOSE', style: Skin.label(size: 10)),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(child: Center(child: _body())),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (!widget.leaderboard.isAvailable) {
      return _message(
        'No leaderboard configured',
        'This build has no scoreboard backend. Your records are still kept '
            'on this device.',
      );
    }
    if (_entries == null) {
      return Text('loading…', style: Skin.label(size: 11));
    }
    if (_failed) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _message(
            'Could not reach the leaderboard',
            'Check your connection and try again.',
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _load,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Skin.accent),
              ),
              child: Text(
                'RETRY',
                style: Skin.label(size: 11, color: Skin.accent),
              ),
            ),
          ),
        ],
      );
    }
    if (_entries!.isEmpty) {
      return _message('No runs yet', 'Be the first to post a time.');
    }

    final you = widget.highlight;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: Panel.maxWidth),
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 20),
        itemCount: _entries!.length,
        itemBuilder: (context, i) {
          final e = _entries![i];
          // Matching on the run's numbers rather than an id: submission is
          // fire-and-forget, so the row comes back from the server without
          // anything tying it to this device.
          final mine =
              you != null &&
              e.name == you.name &&
              (e.time - you.time).abs() < 0.5 &&
              e.kills == you.kills;
          return _row(e, mine);
        },
      ),
    );
  }

  Widget _row(ScoreEntry e, bool mine) {
    final medal = switch (e.rank) {
      1 => const Color(0xFFFFD54A),
      2 => const Color(0xFFCBD5E1),
      3 => const Color(0xFFD08B4A),
      _ => Skin.dim,
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 5),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: mine ? Skin.accent.withValues(alpha: 0.12) : Skin.panel,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: mine ? Skin.accent : Skin.line),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 32,
            child: Text(
              '${e.rank}',
              style: Skin.label(
                size: 12,
                color: medal,
                weight: (e.rank ?? 99) <= 3 ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
          ),
          Expanded(
            child: Text(
              e.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Skin.label(
                size: 12,
                color: mine ? Skin.accent : Skin.text,
                weight: FontWeight.w700,
              ),
            ),
          ),
          _stat('LV', '${e.level}'),
          _stat('G', '${e.generation}'),
          const SizedBox(width: 6),
          Text(
            _clock(e.time),
            style: Skin.label(
              size: 13,
              color: Skin.text,
              weight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _stat(String label, String value) => Padding(
    padding: const EdgeInsets.only(right: 9),
    child: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text('$label ', style: Skin.label(size: 8)),
        Text(value, style: Skin.label(size: 10, color: Skin.dim)),
      ],
    ),
  );

  Widget _message(String title, String detail) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 32),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          title,
          textAlign: TextAlign.center,
          style: Skin.label(
            size: 13,
            color: Skin.text,
            weight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          detail,
          textAlign: TextAlign.center,
          style: Skin.label(size: 10).copyWith(height: 1.6),
        ),
      ],
    ),
  );
}

/// Asks for the name that will appear on the public board.
///
/// Shown once, before the first submission — not at launch, where it would be
/// a wall between the player and the game.
class NamePrompt extends StatefulWidget {
  final String initial;
  final void Function(String name) onSubmit;
  final VoidCallback onSkip;

  /// Wording, so the same prompt serves both the end of a run and a later
  /// change of mind — those are different moments and should not read alike.
  final String title;
  final String blurb;
  final String action;

  const NamePrompt({
    super.key,
    required this.initial,
    required this.onSubmit,
    required this.onSkip,
    this.title = 'POST YOUR RUN',
    this.blurb = 'Pick a name for the global leaderboard.',
    this.action = 'POST',
  });

  @override
  State<NamePrompt> createState() => _NamePromptState();
}

class _NamePromptState extends State<NamePrompt> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _controller.text.trim();
    if (name.isEmpty) {
      widget.onSkip();
      return;
    }
    widget.onSubmit(name);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Skin.bg.withValues(alpha: 0.96),
      child: Panel(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: Skin.label(
                size: 18,
                color: Skin.text,
                weight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              widget.blurb,
              textAlign: TextAlign.center,
              style: Skin.label(size: 10).copyWith(height: 1.5),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _controller,
              autofocus: true,
              // Bounded because this string goes on a public board and into a
              // fixed-width row.
              maxLength: 16,
              textCapitalization: TextCapitalization.none,
              onSubmitted: (_) => _submit(),
              style: Skin.label(size: 14, color: Skin.text),
              decoration: InputDecoration(
                counterStyle: Skin.label(size: 8),
                hintText: 'anonymous',
                hintStyle: Skin.label(size: 14),
                filled: true,
                fillColor: Skin.panel,
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Skin.line),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: const BorderSide(color: Skin.accent, width: 2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            _button(widget.action, Skin.accent, _submit),
            const SizedBox(height: 8),
            _button('NOT NOW', Skin.dim, widget.onSkip),
          ],
        ),
      ),
    );
  }

  Widget _button(String label, Color colour, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          height: 48,
          decoration: BoxDecoration(
            color: colour.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(13),
            border: Border.all(color: colour, width: 2),
          ),
          child: Center(
            child: Text(
              label,
              style: Skin.label(
                size: 13,
                color: colour,
                weight: FontWeight.w700,
              ),
            ),
          ),
        ),
      );
}
