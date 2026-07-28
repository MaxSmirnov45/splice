import 'package:flutter/material.dart';

import 'ability_card.dart';

/// What the game stores, in plain language.
///
/// Short because there is very little to say: the game has no accounts, no
/// analytics and no advertising identifiers of its own. The only thing that
/// ever leaves the device is a leaderboard row, and only when the player
/// chooses to post one.
///
/// Written as specifics rather than the usual boilerplate. A notice that lists
/// exactly which five fields are sent is more use to a player than several
/// paragraphs about "certain information" being processed "in some cases".
class PrivacyScreen extends StatelessWidget {
  final VoidCallback onClose;

  const PrivacyScreen({super.key, required this.onClose});

  static const _sections = <(String, String)>[
    (
      'ON YOUR DEVICE',
      'Your settings, records and which genes you have seen are stored in this '
          'browser or app only. Nothing about them is sent anywhere. Clearing '
          'your browser data erases them.',
    ),
    (
      'ON THE LEADERBOARD',
      'If you post a run, five things are sent: the name you type, how long '
          'you survived, your level, your kills, and your deepest lineage. '
          'That is the whole record. Runs are only posted when you finish one '
          'that beats your own best.',
    ),
    (
      'YOUR NAME IS PUBLIC',
      'Anyone can read the leaderboard, so pick something you are happy to '
          'show strangers. There is no reason to use your real name, and the '
          'game never asks for an email, an account or a password.',
    ),
    (
      'WHAT IS NOT COLLECTED',
      'No accounts, no tracking, no analytics, no advertising identifiers, and '
          'nothing at all that identifies you personally. The game does not '
          'know who you are and has no way to find out.',
    ),
    (
      'THE SITE HOSTING THIS GAME',
      'Wherever you are playing — a game portal, or anywhere else — that site '
          'is a separate company with its own terms and privacy policy, and '
          'any adverts you see come from them rather than from this game.',
    ),
  ];

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
                    'PRIVACY',
                    style: Skin.label(
                      size: 18,
                      color: Skin.text,
                      weight: FontWeight.w700,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: onClose,
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
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: Panel.maxWidth),
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                    children: [
                      for (final (heading, body) in _sections) ...[
                        Text(
                          heading,
                          style: Skin.label(
                            size: 10,
                            color: Skin.accent,
                            weight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          body,
                          style: Skin.label(
                            size: 11.5,
                            color: Skin.text,
                          ).copyWith(height: 1.55),
                        ),
                        const SizedBox(height: 20),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
