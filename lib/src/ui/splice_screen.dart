import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/rng.dart';
import '../game/entities.dart';
import '../game/world.dart';
import '../genome/genes.dart';
import '../genome/genome.dart';
import '../render/atlas.dart';
import 'ability_card.dart';
import 'sigil.dart';

/// The level-up screen, and the place the game's core decision lives.
///
/// Every level offers the same fork: absorb a wild spore to stay broad, or
/// splice two abilities you already own into one stronger child and give up a
/// slot. Because the swarm adapts to whatever payload you lean on, neither
/// answer is right for long.
class SpliceScreen extends StatefulWidget {
  final World world;
  final SpriteAtlas atlas;
  final VoidCallback onDone;

  const SpliceScreen({
    super.key,
    required this.world,
    required this.atlas,
    required this.onDone,
  });

  @override
  State<SpliceScreen> createState() => _SpliceScreenState();
}

class _SpliceScreenState extends State<SpliceScreen> {
  late Genome _spore;
  final List<int> _selected = [];
  bool _sporeSelected = false;

  @override
  void initState() {
    super.initState();
    _rollSpore();
  }

  void _rollSpore() {
    _spore = Genome.wild(widget.world.rng, power: widget.world.level);
    _selected.clear();
    _sporeSelected = false;
  }

  List<Color> _rampFor(Genome g) {
    final key = payloadDefs[g.payload]!.key;
    return widget.atlas.palettes[widget.atlas.payloadPalette[key] ?? 'bone']!;
  }

  bool get _hasFreeSlot => widget.world.abilities.length < maxAbilitySlots;

  /// The offspring of the current selection.
  ///
  /// Seeded from the level and both parents, so it is identical every rebuild.
  /// Without this the player could reroll the mutation by tapping a card off
  /// and on again, which would drain the decision of any weight.
  Genome? get _child {
    if (_selected.length != 2) return null;
    final a = widget.world.abilities[_selected[0]].genome;
    final b = widget.world.abilities[_selected[1]].genome;
    final seed = (widget.world.level * 2654435761) ^ a.seed ^ (b.seed * 31);
    return Genome.splice(a, b, Rng(seed));
  }

  // --- interaction --------------------------------------------------------

  void _tapSpore() {
    setState(() {
      _sporeSelected = !_sporeSelected;
      _selected.clear();
    });
  }

  void _tapAbility(int index) {
    setState(() {
      if (_sporeSelected) {
        // Choosing which ability the spore displaces.
        _selected
          ..clear()
          ..add(index);
        return;
      }
      if (_selected.contains(index)) {
        _selected.remove(index);
      } else {
        if (_selected.length == 2) _selected.removeAt(0);
        _selected.add(index);
      }
    });
  }

  String? get _actionLabel {
    if (_sporeSelected) {
      if (_selected.length == 1) return 'REPLACE';
      if (_hasFreeSlot) return 'ABSORB';
      return null;
    }
    if (_selected.length == 2) return 'SPLICE';
    return null;
  }

  String get _hint {
    if (_sporeSelected) {
      return _hasFreeSlot && _selected.isEmpty
          ? 'Absorb into a free slot, or pick one to replace'
          : 'Pick an ability for the spore to replace';
    }
    if (_selected.length == 1) return 'Pick a second parent';
    if (_selected.length == 2) return 'This offspring consumes both parents';
    return widget.world.abilities.length >= 2
        ? 'Absorb the spore, or pick two abilities to breed'
        : 'Absorb the spore to grow your organism';
  }

  void _confirm() {
    final world = widget.world;

    if (_sporeSelected) {
      if (_selected.length == 1) {
        world.replaceAbility(world.abilities[_selected[0]], _spore);
      } else if (_hasFreeSlot) {
        world.addAbility(_spore);
      } else {
        return;
      }
    } else if (_selected.length == 2) {
      final child = _child!;
      final a = world.abilities[_selected[0]];
      final b = world.abilities[_selected[1]];
      world.spliceAbilities(a, b, child);
    } else {
      return;
    }

    world.pendingLevelUps--;
    if (world.pendingLevelUps > 0) {
      setState(_rollSpore);
    } else {
      widget.onDone();
    }
  }

  // --- build --------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final world = widget.world;
    final action = _actionLabel;

    return Container(
      color: Skin.bg.withValues(alpha: 0.94),
      child: SafeArea(
        child: Column(
          children: [
            _header(world),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 4, 14, 8),
                children: [
                  _sectionLabel('WILD SPORE'),
                  const SizedBox(height: 6),
                  AbilityCard(
                    genome: _spore,
                    atlas: widget.atlas,
                    selected: _sporeSelected,
                    onTap: _tapSpore,
                    badge: 'NEW',
                  ),
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: RiderStrip(genome: _spore, ramp: _rampFor(_spore)),
                  ),
                  const SizedBox(height: 18),
                  _sectionLabel(
                      'ORGANISM  ${world.abilities.length}/$maxAbilitySlots'),
                  const SizedBox(height: 6),
                  for (var i = 0; i < world.abilities.length; i++) ...[
                    AbilityCard(
                      genome: world.abilities[i].genome,
                      atlas: widget.atlas,
                      selected: _selected.contains(i),
                      dimmed: _sporeSelected && !_selected.contains(i),
                      onTap: () => _tapAbility(i),
                      badge: _parentBadge(i),
                    ),
                    const SizedBox(height: 7),
                  ],
                  if (_child != null) ...[
                    const SizedBox(height: 10),
                    _offspringPanel(_child!),
                  ],
                  const SizedBox(height: 12),
                ],
              ),
            ),
            _footer(action),
          ],
        ),
      ),
    );
  }

  String? _parentBadge(int index) {
    if (_sporeSelected) return _selected.contains(index) ? 'REPLACE' : null;
    final pos = _selected.indexOf(index);
    if (pos < 0) return null;
    return pos == 0 ? 'PARENT A' : 'PARENT B';
  }

  Widget _header(World world) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Text('LEVEL ${world.level}',
              style: Skin.label(size: 22, color: Skin.text, weight: FontWeight.w700)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(_hint,
                textAlign: TextAlign.right, style: Skin.label(size: 10, color: Skin.dim)),
          ),
        ],
      ),
    );
  }

  Widget _sectionLabel(String text) => Text(
        text,
        style: Skin.label(size: 9.5, color: Skin.dim, weight: FontWeight.w700),
      );

  /// Preview of the offspring, with the deltas against the stronger parent so
  /// the player can see exactly what the splice buys and what it costs.
  Widget _offspringPanel(Genome child) {
    final ramp = _rampFor(child);
    final a = widget.world.abilities[_selected[0]].genome;
    final b = widget.world.abilities[_selected[1]].genome;
    final best = a.dps >= b.dps ? a : b;
    final delta = child.dps - best.dps;
    final better = delta >= 0;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: ramp[1].withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: ramp[3].withValues(alpha: 0.65), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('OFFSPRING',
                  style: Skin.label(size: 9.5, color: ramp[3], weight: FontWeight.w700)),
              const Spacer(),
              Text(
                '${better ? '+' : ''}${delta.toStringAsFixed(0)} DPS vs best parent',
                style: Skin.label(
                    size: 9.5, color: better ? ramp[3] : Skin.warn, weight: FontWeight.w700),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              SigilTile(genome: child, ramp: ramp, size: 58),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(child.displayName,
                        style: Skin.label(
                            size: 14, color: ramp[4], weight: FontWeight.w700)),
                    const SizedBox(height: 3),
                    Text(
                      '${child.vectors.map((v) => vectorDefs[v]!.name).join(' + ')} · '
                      '${child.payloadLabel} · ${child.triggerLabel}',
                      style: Skin.label(size: 9.5),
                    ),
                    const SizedBox(height: 8),
                    RiderStrip(genome: child, ramp: ramp),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _mutationNote(child, a, b, ramp),
        ],
      ),
    );
  }

  /// Calls out what the mutation actually changed, so the player learns the
  /// system rather than watching numbers shuffle.
  Widget _mutationNote(Genome child, Genome a, Genome b, List<Color> ramp) {
    final notes = <String>[];
    if (child.vector != a.vector && child.vector != b.vector) {
      notes.add('vector mutated to ${vectorDefs[child.vector]!.name}');
    }
    if (child.payload != a.payload && child.payload != b.payload) {
      notes.add('payload mutated to ${payloadDefs[child.payload]!.name}');
    }
    if (child.trigger != a.trigger && child.trigger != b.trigger) {
      notes.add('trigger mutated to ${child.triggerLabel}');
    }
    final gained = child.totalStacks - math.max(a.totalStacks, b.totalStacks);
    if (gained > 0) notes.add('+$gained rider stack${gained == 1 ? '' : 's'}');

    return Text(
      notes.isEmpty ? 'inherited cleanly' : notes.join('  ·  '),
      style: Skin.label(size: 9, color: ramp[3].withValues(alpha: 0.85)),
    );
  }

  Widget _footer(String? action) {
    final enabled = action != null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
      child: SizedBox(
        width: double.infinity,
        height: 52,
        child: GestureDetector(
          onTap: enabled ? _confirm : null,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 130),
            decoration: BoxDecoration(
              color: enabled ? Skin.accent.withValues(alpha: 0.16) : Skin.panel,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: enabled ? Skin.accent : Skin.line,
                width: enabled ? 2 : 1,
              ),
            ),
            child: Center(
              child: Text(
                action ?? 'SELECT AN OPTION',
                style: Skin.label(
                  size: 14,
                  color: enabled ? Skin.accent : Skin.dim,
                  weight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
