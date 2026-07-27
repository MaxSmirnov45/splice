import 'dart:math' as math;

import '../core/rng.dart';
import '../genome/genes.dart';
import '../genome/genome.dart';
import 'entities.dart';
import 'spatial_hash.dart';

/// One equipped ability: a genome plus its live firing state.
class Ability {
  final Genome genome;

  /// Index into the enemy hit-cooldown array. Stable for the ability's life.
  final int slot;

  double cooldown = 0;

  /// Tether only: the enemy currently being ground down.
  Enemy? tetherTarget;

  /// Drives the aura's pulse and the orbit's rotation, purely visual.
  double visualPhase = 0;

  Ability(this.genome, this.slot);
}

/// Simulation state and rules. Knows nothing about rendering or input devices;
/// the game layer feeds it a movement vector and reads it back for drawing.
class World {
  static const double playerBaseSpeed = 108;
  static const double playerRadius = 8.5;
  static const double magnetRange = 52;
  static const double adaptInterval = 14.0;
  static const double maxResistance = 0.72;

  /// Baseline critical hit chance and multiplier.
  ///
  /// Crits exist mainly so the `onCrit` trigger has something to fire on;
  /// without them that gene is inert and any ability rolling it does nothing
  /// at all.
  static const double critChance = 0.09;
  static const double critMultiplier = 2.1;

  /// How close an enemy may pass without touching before it counts as a dodge.
  static const double dodgeMargin = 9.0;

  final Rng rng;

  World(int seed) : rng = Rng(seed) {
    abilities.add(Ability(Genome.starter(), 0));
    for (final p in Payload.values) {
      resistance[p] = 0;
      _damageByPayload[p] = 0;
    }
  }

  // --- player -------------------------------------------------------------
  double px = 0, py = 0;
  double maxHp = 100, hp = 100;
  double invulnerable = 0;

  /// Normalised movement input, set by the input layer each frame.
  double inputX = 0, inputY = 0;

  /// Last non-zero heading, so untargeted abilities still have a direction.
  double facingX = 1, facingY = 0;

  bool get isMoving => inputX != 0 || inputY != 0;

  // --- run state ----------------------------------------------------------
  double time = 0;
  int level = 1;
  double xp = 0;
  double xpToNext = 5;
  int kills = 0;
  int pendingLevelUps = 0;
  bool gameOver = false;

  /// View half-extents in world units, set by the renderer. Used to spawn
  /// enemies just outside what the player can see.
  double viewHalfWidth = 240, viewHalfHeight = 420;

  final List<Ability> abilities = [];
  int _nextSlot = 1;

  /// Every genome the player has held this run, including ones since consumed
  /// by a splice. Feeds the persistent codex at the end of the run.
  final List<Genome> heldGenomes = [Genome.starter()];

  // --- pools --------------------------------------------------------------
  final Pool<Enemy> enemyPool = Pool(700, () => Enemy(), (e) => e.alive);
  final Pool<Shot> shotPool = Pool(500, () => Shot(), (s) => s.alive);
  final Pool<Pickup> pickupPool = Pool(400, () => Pickup(), (p) => p.alive);
  final Pool<Particle> particlePool = Pool(700, () => Particle(), (p) => p.alive);
  final Pool<Arc> arcPool = Pool(64, () => Arc(), (a) => a.alive);

  late final SpatialHash _hash = SpatialHash(enemyPool.capacity);

  List<Enemy> get enemies => enemyPool.items;
  List<Shot> get shots => shotPool.items;
  List<Pickup> get pickups => pickupPool.items;
  List<Particle> get particles => particlePool.items;
  List<Arc> get arcs => arcPool.items;

  // --- adaptation ---------------------------------------------------------
  /// Current swarm resistance per damage type, 0..[maxResistance].
  final Map<Payload, double> resistance = {};
  final Map<Payload, double> _damageByPayload = {};
  double _adaptTimer = adaptInterval;

  /// Set when the swarm adapts, so the HUD can announce it. Cleared by the UI.
  Payload? lastAdaptedPayload;
  double adaptNoticeTime = 0;

  /// Sound hook. Left null in tests and headless benchmarks so the simulation
  /// has no dependency on an audio backend. Throttling lives in the player,
  /// not here — the world reports every event and lets playback decide.
  void Function(String id)? onSound;

  // --- spawning -----------------------------------------------------------
  double _spawnTimer = 0;
  double _nextEliteAt = 70;

  /// Scratch list reused by chain targeting, so it never allocates mid-frame.
  final List<Enemy> _chainHits = [];

  // ========================================================================

  void update(double dt) {
    if (gameOver || pendingLevelUps > 0) return;

    // Clamp so a dropped frame or a backgrounded app cannot tunnel entities
    // through each other.
    if (dt > 1 / 20) dt = 1 / 20;

    time += dt;
    if (invulnerable > 0) invulnerable -= dt;
    if (adaptNoticeTime > 0) adaptNoticeTime -= dt;

    _updatePlayer(dt);
    _hash.rebuild(enemies, px, py);
    _updateAbilities(dt);
    _updateShots(dt);
    _updateEnemies(dt);
    _flushEvents();
    _updatePickups(dt);
    _updateParticles(dt);
    _updateArcs(dt);
    _updateSpawning(dt);
    _updateAdaptation(dt);
  }

  // --- player -------------------------------------------------------------

  void _updatePlayer(double dt) {
    if (inputX != 0 || inputY != 0) {
      facingX = inputX;
      facingY = inputY;
    }
    px += inputX * playerBaseSpeed * dt;
    py += inputY * playerBaseSpeed * dt;
  }

  void _hurt(double amount) {
    if (invulnerable > 0 || gameOver) return;
    hp -= amount;
    invulnerable = 0.55;
    onSound?.call('hurt');
    _queueEvent(Trigger.onHurt);
    _burstParticles(px, py, 8, Payload.bleed, speed: 90, life: 0.4);
    if (hp <= 0) {
      hp = 0;
      gameOver = true;
    }
  }

  void heal(double amount) {
    hp = math.min(maxHp, hp + amount);
  }

  /// Revives allowed per run.
  static const int maxRevives = 1;

  int revivesUsed = 0;

  bool get canRevive => revivesUsed < maxRevives;

  /// Brings the player back mid-run with everything they had built intact.
  ///
  /// Clearing the immediate area matters as much as the health: reviving into
  /// the same wall of enemies that just killed you would waste the revive
  /// inside a second.
  void revive() {
    if (!gameOver) return;
    revivesUsed++;
    gameOver = false;
    _gameOverEmitted = false;
    hp = maxHp * 0.6;
    invulnerable = 3.0;
    _pendingEvents.clear();

    const clearRadius = 190.0;
    for (final e in enemies) {
      if (!e.alive) continue;
      final dx = e.x - px, dy = e.y - py;
      if (dx * dx + dy * dy > clearRadius * clearRadius) continue;
      e.alive = false;
      _burstParticles(e.x, e.y, 4, Payload.voidp, speed: 130, life: 0.5, frame: 'shard');
    }
    _spawnRing(px, py, clearRadius, Payload.voidp);
  }

  /// Set once the game-over hook has fired, so reviving can re-arm it.
  bool _gameOverEmitted = false;

  bool get gameOverEmitted => _gameOverEmitted;

  void markGameOverEmitted() => _gameOverEmitted = true;

  // --- abilities ----------------------------------------------------------

  void _updateAbilities(double dt) {
    // An event-driven ability cannot start itself: an on-kill effect needs
    // something else to produce the first kill, and on-hurt needs to be hit.
    // A loadout made entirely of them is unplayable — nothing ever fires and
    // the run is silently over. When that happens, let them run on their
    // cooldowns instead, which keeps the game alive without weakening the
    // trigger in any normal loadout.
    var selfStarting = false;
    for (final a in abilities) {
      if (!triggerDefs[a.genome.trigger]!.eventDriven) {
        selfStarting = true;
        break;
      }
    }

    for (final a in abilities) {
      a.visualPhase += dt;
      if (a.cooldown > 0) a.cooldown -= dt;

      final def = triggerDefs[a.genome.trigger]!;
      if (def.eventDriven && selfStarting) continue; // fired by _flushEvents

      var allowed = true;
      switch (a.genome.trigger) {
        case Trigger.onMove:
          allowed = isMoving;
          break;
        case Trigger.onStill:
          allowed = !isMoving;
          break;
        case Trigger.onLowHp:
          allowed = hp < maxHp * 0.34;
          break;
        default:
          allowed = true;
      }
      if (allowed && a.cooldown <= 0) _activate(a);
    }

    _maintainOrbits();
  }

  /// Trigger events raised during the current frame.
  ///
  /// Deferred rather than dispatched inline. Firing an on-kill ability from
  /// inside the kill that raised it can kill again and recurse arbitrarily
  /// deep; collecting into a set and flushing once per frame bounds that, and
  /// collapses a hundred simultaneous kills into the one activation the
  /// ability's cooldown would have allowed anyway.
  final Set<Trigger> _pendingEvents = {};

  void _queueEvent(Trigger t) => _pendingEvents.add(t);

  void _flushEvents() {
    if (_pendingEvents.isEmpty) return;
    // Snapshot and clear first: activations may queue further events, which
    // belong to the next frame rather than this one.
    final events = List<Trigger>.of(_pendingEvents);
    _pendingEvents.clear();
    for (final t in events) {
      for (final a in abilities) {
        if (a.genome.trigger == t && a.cooldown <= 0) _activate(a);
      }
    }
  }

  void _activate(Ability a) {
    a.cooldown = a.genome.cooldown;
    onSound?.call('shoot');
    _fire(a);
    // Echo re-fires immediately. Rolled per activation, so a high-echo genome
    // visibly stutters out extra volleys rather than just having more dps.
    if (a.genome.echoChance > 0 && rng.chance(a.genome.echoChance)) _fire(a);
  }

  /// Fires everything the genome delivers: the primary vector, and the
  /// secondary inherited from the other parent if the lineage is a hybrid.
  void _fire(Ability a) {
    final g = a.genome;
    _fireVector(a, g.vector, g.damage, g.count, g.payload, g.range, a.slot);

    final sub = g.subVector;
    if (sub != null) {
      // Offset hit slot: the secondary needs its own per-enemy lockout or the
      // two halves of a hybrid block each other's hits.
      _fireVector(a, sub, g.subDamage, g.subCount, g.subPayload ?? g.payload,
          g.subRange, a.slot + maxAbilitySlots);
    }
  }

  /// [range] is passed explicitly rather than read off the genome: the
  /// secondary vector has its own reach, and sharing the primary's produces
  /// auras the size of the screen or beams too short to connect.
  void _fireVector(Ability a, Vector v, double damage, int count, Payload payload,
      double range, int hitSlot) {
    switch (v) {
      case Vector.bolt:
        _fireProjectiles(a, ShotKind.bolt, damage, count, payload, range, hitSlot);
        break;
      case Vector.swarm:
        _fireProjectiles(a, ShotKind.seeker, damage, count, payload, range, hitSlot);
        break;
      case Vector.aura:
        _applyRadial(a, px, py, range, damage, payload, hitSlot, ring: false);
        break;
      case Vector.burst:
        _applyRadial(a, px, py, range, damage, payload, hitSlot, ring: true);
        break;
      case Vector.beam:
        _fireBeam(a, damage, payload, range, hitSlot);
        break;
      case Vector.chain:
        _fireChain(a, damage, payload, range);
        break;
      case Vector.tether:
        _fireTether(a, damage, payload, range);
        break;
      case Vector.mine:
        _fireMines(a, damage, count, payload, range, hitSlot);
        break;
      case Vector.wave:
        _fireWaves(a, damage, count, payload, range, hitSlot);
        break;
      case Vector.orbit:
        // Orbits persist; _maintainOrbits keeps the right number alive and the
        // ability's cooldown gates how often each one may damage an enemy.
        break;
    }
  }

  void _fireProjectiles(Ability a, ShotKind kind, double damage, int count,
      Payload payload, double range, int hitSlot) {
    final target = _nearest(px, py, range);
    var dirX = facingX, dirY = facingY;
    if (target != null) {
      dirX = target.x - px;
      dirY = target.y - py;
      final len = math.sqrt(dirX * dirX + dirY * dirY);
      if (len > 0) {
        dirX /= len;
        dirY /= len;
      }
    }

    // Fan multiple instances across a modest arc so splits read as a volley.
    final vdef = vectorDefs[kind == ShotKind.seeker ? Vector.swarm : Vector.bolt]!;
    final spread = count > 1 ? math.min(0.9, 0.16 * count) : 0.0;
    final base = math.atan2(dirY, dirX) - spread / 2;
    for (var i = 0; i < count; i++) {
      final s = shotPool.obtain();
      if (s == null) return;
      final ang = count > 1 ? base + spread * (i / (count - 1)) : base;
      _initShot(s, a, kind, px, py, damage, payload, hitSlot);
      s.vx = math.cos(ang) * vdef.speed;
      s.vy = math.sin(ang) * vdef.speed;
      s.life = vdef.life;
      s.radius = 5 + range * 0.006;
      s.spin = ang;
    }
  }

  void _fireMines(Ability a, double damage, int count, Payload payload, double range,
      int hitSlot) {
    final vdef = vectorDefs[Vector.mine]!;
    for (var i = 0; i < count; i++) {
      final s = shotPool.obtain();
      if (s == null) return;
      _initShot(s, a, ShotKind.mine, px + rng.range(-14, 14), py + rng.range(-14, 14),
          damage, payload, hitSlot);
      s.life = vdef.life;
      s.radius = range * 0.42;
    }
  }

  void _fireWaves(Ability a, double damage, int count, Payload payload, double range,
      int hitSlot) {
    final vdef = vectorDefs[Vector.wave]!;
    for (var i = 0; i < count; i++) {
      final s = shotPool.obtain();
      if (s == null) return;
      _initShot(s, a, ShotKind.wave, px, py, damage, payload, hitSlot);
      s.life = vdef.life;
      // Stagger multiple waves so they read as concentric pulses.
      s.waveRadius = -i * 26.0;
      s.waveMax = range;
      s.radius = 10;
    }
  }

  void _initShot(Shot s, Ability a, ShotKind kind, double x, double y, double damage,
      Payload payload, int hitSlot) {
    final g = a.genome;
    s.alive = true;
    s.kind = kind;
    s.payload = payload;
    s.x = x;
    s.y = y;
    s.vx = s.vy = 0;
    s.damage = damage;
    s.knockback = g.knockback;
    s.seek = g.seekStrength;
    s.pierce = g.pierce;
    s.slot = hitSlot;
    s.statusDuration = g.statusDuration;
    s.dotPerSecond = g.dotPerSecond;
    s.spin = 0;
  }

  /// Keeps each orbit ability's satellites alive and correctly numbered.
  ///
  /// Handles orbit as either the primary or the secondary vector, so a hybrid
  /// like Bolt-Orbit still gets its satellites.
  void _maintainOrbits() {
    for (final a in abilities) {
      final g = a.genome;
      final isPrimary = g.vector == Vector.orbit;
      final isSub = g.subVector == Vector.orbit;
      if (!isPrimary && !isSub) continue;

      final want = isPrimary ? g.count : g.subCount;
      final damage = isPrimary ? g.damage : g.subDamage;
      final payload = isPrimary ? g.payload : (g.subPayload ?? g.payload);
      // Must match the slot the satellites are created with. Counting against
      // the wrong one makes `live` permanently zero, so a new orbit spawns
      // every frame until the shot pool is exhausted — which breaks the
      // ability and starves every other projectile in the game.
      final hitSlot = isPrimary ? a.slot : a.slot + maxAbilitySlots;

      var live = 0;
      for (final s in shots) {
        if (s.alive && s.kind == ShotKind.orbit && s.slot == hitSlot) live++;
      }
      for (var i = live; i < want; i++) {
        final s = shotPool.obtain();
        if (s == null) break;
        _initShot(s, a, ShotKind.orbit, px, py, damage, payload, hitSlot);
        s.life = 0; // persists until the ability changes
        s.orbitRadius = isPrimary ? g.range : g.subRange;
        s.angularSpeed = vectorDefs[Vector.orbit]!.speed;
        s.angle = (i / math.max(1, want)) * math.pi * 2;
        // Generous hitbox: covers the gap between the player and the orbit ring
        // so enemies pressed against the player are still swept.
        s.radius = 11;
        s.pierce = -1;
      }
    }
  }

  /// Damages everything inside a circle. Used by aura and burst.
  void _applyRadial(Ability a, double cx, double cy, double radius, double damage,
      Payload payload, int hitSlot,
      {required bool ring}) {
    final g = a.genome;
    var hitAny = false;
    _hash.forEachNear(cx, cy, radius, (i) {
      final e = enemies[i];
      if (!e.alive || e.hitCooldown[hitSlot] > 0) return;
      final dx = e.x - cx, dy = e.y - cy;
      final r = radius + e.radius;
      if (dx * dx + dy * dy > r * r) return;
      e.hitCooldown[hitSlot] = g.cooldown * 0.95;
      _damage(e, damage, g, a.slot, dx, dy, payload);
      hitAny = true;
    });

    if (ring) {
      _spawnRing(cx, cy, radius, payload);
    } else if (hitAny) {
      _burstParticles(cx, cy, 2, payload, speed: 40, life: 0.3);
    }
  }

  void _fireBeam(Ability a, double damage, Payload payload, double range, int hitSlot) {
    final g = a.genome;
    final target = _nearest(px, py, range);
    var dx = facingX, dy = facingY;
    if (target != null) {
      dx = target.x - px;
      dy = target.y - py;
      final len = math.sqrt(dx * dx + dy * dy);
      if (len > 0) {
        dx /= len;
        dy /= len;
      }
    }

    _spawnArc(px, py, px + dx * range, py + dy * range, payload,
        life: 0.16, width: 5.0 + a.genome.visualTier * 0.8);

    const halfWidth = 11.0;
    // Walk the beam in steps and damage whatever each step overlaps. Cheaper
    // and more predictable than an exact segment-circle test per enemy.
    final steps = (range / 18).ceil();
    for (var i = 1; i <= steps; i++) {
      final t = (i / steps) * range;
      final bx = px + dx * t, by = py + dy * t;
      _hash.forEachNear(bx, by, halfWidth, (idx) {
        final e = enemies[idx];
        if (!e.alive || e.hitCooldown[hitSlot] > 0) return;
        final ex = e.x - bx, ey = e.y - by;
        final r = halfWidth + e.radius;
        if (ex * ex + ey * ey > r * r) return;
        e.hitCooldown[hitSlot] = g.cooldown * 0.9;
        _damage(e, damage, g, a.slot, dx, dy, payload);
      });
      if (i % 2 == 0) {
        _spawnParticle('spark_${payloadDefs[payload]!.key}', bx, by,
            vx: 0, vy: 0, life: 0.18, scale: 1.4, drag: 0.1);
      }
    }
  }

  void _fireChain(Ability a, double damage, Payload payload, double range) {
    final g = a.genome;
    _chainHits.clear();
    var fromX = px, fromY = py;
    final jumps = g.pierce < 0 ? 6 : g.pierce + 1;

    for (var j = 0; j < jumps; j++) {
      final next = _nearest(fromX, fromY, range, exclude: _chainHits);
      if (next == null) break;
      _chainHits.add(next);
      _spawnBeamTrail(fromX, fromY, next.x, next.y, payload);
      _spawnArc(fromX, fromY, next.x, next.y, payload,
          width: 2.6 + g.visualTier * 0.5);
      // Each jump lands for slightly less, so long chains do not eclipse
      // every other vector in dense waves.
      _damage(next, damage * math.pow(0.88, j).toDouble(), g, a.slot,
          next.x - fromX, next.y - fromY, payload);
      fromX = next.x;
      fromY = next.y;
    }
  }

  void _fireTether(Ability a, double damage, Payload payload, double range) {
    final g = a.genome;
    var target = a.tetherTarget;
    if (target == null || !target.alive || _dist2(target.x, target.y, px, py) > range * range) {
      target = _nearest(px, py, range);
      a.tetherTarget = target;
    }
    if (target == null) return;
    _damage(target, damage, g, a.slot, target.x - px, target.y - py, payload);
  }

  // --- damage -------------------------------------------------------------

  /// Applies damage, statuses and knockback, and resolves death.
  ///
  /// [dirX]/[dirY] point from the source toward the enemy and need not be
  /// normalised; they only set the knockback direction.
  void _damage(Enemy e, double amount, Genome g, int slot, double dirX, double dirY,
      Payload payload) {
    if (!e.alive) return;

    var resist = resistance[payload] ?? 0;
    // Corrode is the direct answer to adaptation: it strips most of whatever
    // resistance the swarm has built up.
    if (e.corrodeTime > 0) resist *= 0.4;
    // Void bypasses resistance entirely, which is why its base damage is low.
    if (payload == Payload.voidp) resist = 0;

    final crit = rng.chance(critChance);
    final dealt = amount * (crit ? critMultiplier : 1.0) * (1 - resist);
    e.hp -= dealt;
    e.flash = crit ? 0.2 : 0.12;
    if (crit) _queueEvent(Trigger.onCrit);
    _damageByPayload[payload] = (_damageByPayload[payload] ?? 0) + dealt;

    _applyStatus(e, g, dealt, payload);
    // A genome that hybridised its payload but not its vector has only one
    // delivery to ride on, so that delivery carries both effects.
    final sub = g.subPayload;
    if (sub != null && g.subVector == null && payload == g.payload) {
      _applyStatus(e, g, dealt * 0.6, sub);
    }

    if (g.knockback > 0) {
      final len = math.sqrt(dirX * dirX + dirY * dirY);
      if (len > 0.0001) {
        final impulse = g.knockback * 42;
        e.vx += (dirX / len) * impulse;
        e.vy += (dirY / len) * impulse;
      }
    }

    if (g.leechFraction > 0) heal(dealt * g.leechFraction);

    if (e.hp <= 0) {
      _kill(e, g, slot, payload);
    } else {
      onSound?.call('hit');
      // A wide aura can land dozens of hits per frame; one spark each floods
      // the pool and buys nothing visually.
      if (rng.chance(0.45)) {
        _spawnParticle('spark_${payloadDefs[payload]!.key}', e.x, e.y,
            vx: rng.range(-30, 30), vy: rng.range(-30, 30),
            life: 0.25, scale: 1.0, drag: 0.2);
      }
    }
  }

  /// Applies [payload]'s status effect to [e].
  ///
  /// Duration and damage-over-time are read from the payload that actually
  /// landed, not from the genome's primary. Using the primary's numbers meant
  /// a Frost secondary behind a Kinetic primary applied no slow at all —
  /// Kinetic's status duration is zero — so half of every hybrid's payload
  /// identity silently did nothing.
  void _applyStatus(Enemy e, Genome g, double dealt, Payload payload) {
    final def = payloadDefs[payload]!;
    final duration = def.statusDuration * g.fermentScale;
    final dot = def.dotPerSecond;

    switch (payload) {
      case Payload.burn:
        e.burnTime = math.max(e.burnTime, duration);
        e.burnDps = math.max(e.burnDps, dealt * dot);
        e.dotPayload = Payload.burn;
        break;
      case Payload.bleed:
        // Scales with how fast the target moves, so it punishes the quick swarm
        // and does comparatively little to a brute.
        final speedFactor = (e.def.speed / 50).clamp(0.5, 2.5);
        e.burnTime = math.max(e.burnTime, duration);
        e.burnDps = math.max(e.burnDps, dealt * dot * speedFactor);
        e.dotPayload = Payload.bleed;
        break;
      case Payload.frost:
        e.slowTime = math.max(e.slowTime, duration);
        e.slowFactor = 0.55;
        break;
      case Payload.corrode:
        e.corrodeTime = math.max(e.corrodeTime, duration);
        break;
      case Payload.shock:
        e.stunTime = math.max(e.stunTime, duration);
        break;
      case Payload.kinetic:
      case Payload.voidp:
        break;
    }
  }

  void _kill(Enemy e, Genome g, int slot, Payload payload) {
    e.alive = false;
    kills++;
    onSound?.call('kill');

    // Higher-tier abilities kill louder: more debris, thrown further.
    final tier = g.visualTier;
    _burstParticles(e.x, e.y, math.min(9, 5 + tier), payload,
        speed: 110 + tier * 22, life: 0.45, frame: 'shard');
    // Only a fraction of kills throw a ring. At a dozen kills a second every
    // one of them spawning a stroked circle is pure cost for no clarity.
    if (tier >= 3 && rng.chance(0.25)) {
      _spawnRing(e.x, e.y, 14.0 + tier * 3, payload);
    }

    final xpValue = e.def.xp * (1 + g.greedBonus);
    _dropPickup(e.x, e.y, xpValue, isHealth: false);
    // Occasional healing drop, weighted toward bigger enemies.
    if (rng.chance(0.012 + e.def.xp * 0.0015)) {
      _dropPickup(e.x + rng.range(-6, 6), e.y + rng.range(-6, 6), 12, isHealth: true);
    }

    // Bloom seeds a small secondary detonation where the enemy died.
    if (g.bloomChance > 0 && rng.chance(g.bloomChance)) {
      _bloom(e.x, e.y, g, payload);
    }

    _queueEvent(Trigger.onKill);
  }

  void _bloom(double x, double y, Genome g, Payload payload) {
    const radius = 46.0;
    _spawnRing(x, y, radius, payload);
    _hash.forEachNear(x, y, radius, (i) {
      final e = enemies[i];
      if (!e.alive) return;
      final dx = e.x - x, dy = e.y - y;
      final r = radius + e.radius;
      if (dx * dx + dy * dy > r * r) return;
      // Bloom deals a fraction and cannot itself bloom, so chains terminate.
      final resist = g.payload == Payload.voidp ? 0.0 : (resistance[g.payload] ?? 0);
      e.hp -= g.damage * 0.5 * (1 - resist);
      e.flash = 0.12;
      if (e.hp <= 0) {
        e.alive = false;
        kills++;
        _dropPickup(e.x, e.y, e.def.xp * (1 + g.greedBonus));
        _burstParticles(e.x, e.y, 4, g.payload, speed: 90, life: 0.4, frame: 'shard');
      }
    });
  }

  // --- enemies ------------------------------------------------------------

  void _updateEnemies(double dt) {
    for (var i = 0; i < enemies.length; i++) {
      final e = enemies[i];
      if (!e.alive) continue;

      for (var s = 0; s < e.hitCooldown.length; s++) {
        if (e.hitCooldown[s] > 0) e.hitCooldown[s] -= dt;
      }
      if (e.flash > 0) e.flash -= dt;
      if (e.slowTime > 0) {
        e.slowTime -= dt;
        if (e.slowTime <= 0) e.slowFactor = 1.0;
      }
      if (e.corrodeTime > 0) e.corrodeTime -= dt;
      if (e.stunTime > 0) e.stunTime -= dt;

      if (e.burnTime > 0) {
        e.burnTime -= dt;
        e.hp -= e.burnDps * dt;
        if (rng.chance(dt * 6)) {
          _spawnParticle('spark_${payloadDefs[e.dotPayload]!.key}', e.x, e.y,
              vx: rng.range(-12, 12), vy: -22, life: 0.35, scale: 0.9, drag: 0.4);
        }
        if (e.hp <= 0) {
          // Death by lingering damage still pays out, but has no ability
          // context, so it cannot bloom or trigger on-kill effects.
          e.alive = false;
          kills++;
          _dropPickup(e.x, e.y, e.def.xp);
          _burstParticles(e.x, e.y, 5, e.dotPayload, speed: 90, life: 0.4, frame: 'shard');
          continue;
        }
      }

      _steerEnemy(e, dt);
      _separate(e, i);

      e.x += e.vx * dt;
      e.y += e.vy * dt;
      // Knockback impulses bleed off; steering re-establishes intent.
      e.vx *= 0.86;
      e.vy *= 0.86;

      final dx = px - e.x, dy = py - e.y;
      final touch = playerRadius + e.radius;
      final d2 = dx * dx + dy * dy;
      if (d2 < touch * touch) {
        _hurt(e.def.contactDamage);
      } else if (d2 < (touch + dodgeMargin) * (touch + dodgeMargin)) {
        // Grazed but not hit. Without this the onDodge gene never fires.
        _queueEvent(Trigger.onDodge);
      }
    }
  }

  void _steerEnemy(Enemy e, double dt) {
    if (e.stunTime > 0) return;

    var dx = px - e.x, dy = py - e.y;
    final dist = math.sqrt(dx * dx + dy * dy);
    if (dist < 0.001) return;
    dx /= dist;
    dy /= dist;

    final speed = e.def.speed * (e.slowTime > 0 ? e.slowFactor : 1.0);
    e.phase += dt;

    switch (e.def.behaviour) {
      case EnemyBehaviour.chase:
        break;
      case EnemyBehaviour.weave:
        // Sideways oscillation keeps packs from collapsing into one line.
        final swing = math.sin(e.phase * 2.6) * 0.55;
        final nx = -dy, ny = dx;
        dx += nx * swing;
        dy += ny * swing;
        break;
      case EnemyBehaviour.orbit:
        // Holds a standoff distance and circles it.
        final desired = 120.0;
        final radial = (dist - desired) / desired;
        final nx = -dy, ny = dx;
        dx = dx * radial.clamp(-1.0, 1.0) + nx * 0.9;
        dy = dy * radial.clamp(-1.0, 1.0) + ny * 0.9;
        break;
      case EnemyBehaviour.lunge:
        e.actionTimer -= dt;
        if (e.actionTimer <= 0) e.actionTimer = 1.9;
        // Charges hard for the first third of the cycle, coasts for the rest.
        final charging = e.actionTimer > 1.25;
        if (!charging) {
          dx *= 0.15;
          dy *= 0.15;
        } else {
          dx *= 2.1;
          dy *= 2.1;
        }
        break;
    }

    final len = math.sqrt(dx * dx + dy * dy);
    if (len > 0.001) {
      e.vx += (dx / len) * speed * 8 * dt;
      e.vy += (dy / len) * speed * 8 * dt;
    }

    // Cap so knockback and steering cannot compound into absurd velocities.
    final vlen = math.sqrt(e.vx * e.vx + e.vy * e.vy);
    final cap = speed * 2.6;
    if (vlen > cap) {
      e.vx = e.vx / vlen * cap;
      e.vy = e.vy / vlen * cap;
    }
  }

  /// Pushes overlapping enemies apart so a swarm reads as a crowd rather than
  /// a single stacked sprite.
  void _separate(Enemy e, int selfIndex) {
    final r = e.radius * 1.6;
    _hash.forEachNear(e.x, e.y, r, (i) {
      if (i == selfIndex) return;
      final o = enemies[i];
      if (!o.alive) return;
      final dx = e.x - o.x, dy = e.y - o.y;
      final min = e.radius + o.radius;
      final d2 = dx * dx + dy * dy;
      if (d2 >= min * min || d2 < 0.0001) return;
      final d = math.sqrt(d2);
      final push = (min - d) / min;
      e.vx += (dx / d) * push * 90;
      e.vy += (dy / d) * push * 90;
    });
  }

  // --- shots --------------------------------------------------------------

  void _updateShots(double dt) {
    for (final s in shots) {
      if (!s.alive) continue;

      switch (s.kind) {
        case ShotKind.orbit:
          final a = abilityForSlot(s.slot);
          if (a == null) {
            s.alive = false;
            continue;
          }
          s.angle += s.angularSpeed * dt;
          s.orbitRadius = a.genome.range;
          s.x = px + math.cos(s.angle) * s.orbitRadius;
          s.y = py + math.sin(s.angle) * s.orbitRadius;
          s.spin = s.angle;
          break;

        case ShotKind.seeker:
          final target = _nearest(s.x, s.y, 260);
          if (target != null) {
            var dx = target.x - s.x, dy = target.y - s.y;
            final len = math.sqrt(dx * dx + dy * dy);
            if (len > 0.001) {
              dx /= len;
              dy /= len;
              final turn = (2.2 + s.seek * 5.0) * dt;
              s.vx += dx * turn * 260;
              s.vy += dy * turn * 260;
              final speed = math.sqrt(s.vx * s.vx + s.vy * s.vy);
              final want = 190 + s.seek * 60;
              if (speed > 0.001) {
                s.vx = s.vx / speed * want;
                s.vy = s.vy / speed * want;
              }
            }
          }
          s.x += s.vx * dt;
          s.y += s.vy * dt;
          s.spin = math.atan2(s.vy, s.vx);
          break;

        case ShotKind.wave:
          s.waveRadius += 210 * dt;
          if (s.waveRadius > s.waveMax) {
            s.alive = false;
            continue;
          }
          break;

        case ShotKind.bolt:
          s.x += s.vx * dt;
          s.y += s.vy * dt;
          break;

        case ShotKind.mine:
          break;
      }

      if (s.life > 0) {
        s.life -= dt;
        if (s.life <= 0) {
          s.alive = false;
          continue;
        }
      }

      _collideShot(s);
    }
  }

  void _collideShot(Shot s) {
    final ability = abilityForSlot(s.slot);
    if (ability == null) return;
    final g = ability.genome;

    if (s.kind == ShotKind.wave) {
      // A wave only damages the enemies its expanding edge is currently
      // sweeping across, not everything inside it.
      const band = 16.0;
      _hash.forEachNear(s.x, s.y, s.waveRadius + band, (i) {
        final e = enemies[i];
        if (!e.alive || e.hitCooldown[s.slot] > 0) return;
        final dx = e.x - s.x, dy = e.y - s.y;
        final d = math.sqrt(dx * dx + dy * dy);
        if ((d - s.waveRadius).abs() > band + e.radius) return;
        e.hitCooldown[s.slot] = 0.4;
        _damage(e, s.damage, g, s.slot, dx, dy, s.payload);
      });
      return;
    }

    _hash.forEachNear(s.x, s.y, s.radius + 20, (i) {
      if (!s.alive) return;
      final e = enemies[i];
      if (!e.alive || e.hitCooldown[s.slot] > 0) return;
      final dx = e.x - s.x, dy = e.y - s.y;
      final r = s.radius + e.radius;
      if (dx * dx + dy * dy > r * r) return;

      // Persistent vectors re-hit on the ability's cadence; one-shot
      // projectiles use a short lockout purely to avoid double-hits.
      e.hitCooldown[s.slot] =
          (s.kind == ShotKind.orbit || s.kind == ShotKind.mine) ? g.cooldown * 0.95 : 0.05;
      _damage(e, s.damage, g, s.slot, s.kind == ShotKind.mine ? dx : s.vx,
          s.kind == ShotKind.mine ? dy : s.vy, s.payload);

      if (s.pierce >= 0) {
        if (s.pierce == 0) {
          s.alive = false;
        } else {
          s.pierce--;
        }
      }
    });
  }

  /// The ability occupying [slot], or null if it has been consumed.
  /// Public because the renderer needs each shot's genome to know how
  /// elaborately to draw it.
  Ability? abilityForSlot(int hitSlot) {
    final slot = hitSlot % maxAbilitySlots;
    for (final a in abilities) {
      if (a.slot == slot) return a;
    }
    return null;
  }

  // --- pickups ------------------------------------------------------------

  void _dropPickup(double x, double y, double value, {bool isHealth = false}) {
    final p = pickupPool.obtain();
    if (p == null) return;
    p.alive = true;
    p.x = x;
    p.y = y;
    p.vx = rng.range(-26, 26);
    p.vy = rng.range(-26, 26);
    p.value = value;
    p.isHealth = isHealth;
    p.attracted = false;
    p.homeSpeed = 0;
  }

  /// Homing speed a pickup latches on at, how fast it builds, and its cap.
  static const double _pickupStartSpeed = 90;
  static const double _pickupAccel = 1500;
  static const double _pickupMaxSpeed = 620;

  void _updatePickups(double dt) {
    for (final p in pickups) {
      if (!p.alive) continue;

      final dx = px - p.x, dy = py - p.y;
      final d2 = dx * dx + dy * dy;

      if (!p.attracted && d2 < magnetRange * magnetRange) {
        p.attracted = true;
        p.homeSpeed = _pickupStartSpeed;
      }

      if (p.attracted) {
        final d = math.sqrt(d2);
        p.homeSpeed = math.min(_pickupMaxSpeed, p.homeSpeed + _pickupAccel * dt);
        final step = p.homeSpeed * dt;

        // Steer straight at the player instead of accumulating force toward
        // them. Force-based attraction builds lateral velocity, so the mote
        // sails past and orbits; direct steering always closes the distance.
        if (d <= step + playerRadius + 4) {
          // It would reach the player within this frame. Collect now rather
          // than stepping past and having to swing back around.
          _collect(p);
          continue;
        }
        p.x += (dx / d) * step;
        p.y += (dy / d) * step;
        continue;
      }

      // Loose scatter until the magnet takes over.
      p.vx *= 0.9;
      p.vy *= 0.9;
      p.x += p.vx * dt;
      p.y += p.vy * dt;

      if (d2 < (playerRadius + 6) * (playerRadius + 6)) _collect(p);
    }
  }

  void _collect(Pickup p) {
    p.alive = false;
    onSound?.call('pickup');
    if (p.isHealth) {
      heal(p.value);
    } else {
      _gainXp(p.value);
    }
  }

  void _gainXp(double amount) {
    xp += amount;
    while (xp >= xpToNext) {
      xp -= xpToNext;
      level++;
      pendingLevelUps++;
      onSound?.call('levelup');
      // Curve is deliberately shallow early so the first few Splice screens
      // arrive quickly and teach the mechanic.
      xpToNext = 5 + level * 3.4 + level * level * 0.55;
    }
  }

  // --- particles ----------------------------------------------------------

  void _spawnParticle(String frame, double x, double y,
      {double vx = 0,
      double vy = 0,
      double life = 0.4,
      double scale = 1.0,
      double drag = 1.0,
      double spinRate = 0,
      int color = 0xFFFFFFFF}) {
    // Bounded scan: particles are cosmetic, so giving up early on a full
    // pool is far cheaper than searching all 700 slots to find nothing.
    final p = particlePool.obtain(maxScan: 96);
    if (p == null) return;
    p.alive = true;
    p.frame = frame;
    p.x = x;
    p.y = y;
    p.vx = vx;
    p.vy = vy;
    p.life = life;
    p.maxLife = life;
    p.scale = scale;
    p.drag = drag;
    p.spin = 0;
    p.spinRate = spinRate;
    p.color = color;
  }

  void _burstParticles(double x, double y, int n, Payload payload,
      {double speed = 80, double life = 0.4, String frame = 'spark'}) {
    final key = payloadDefs[payload]!.key;
    for (var i = 0; i < n; i++) {
      final ang = rng.range(0, math.pi * 2);
      final sp = rng.range(speed * 0.4, speed);
      _spawnParticle('${frame}_$key', x, y,
          vx: math.cos(ang) * sp,
          vy: math.sin(ang) * sp,
          life: life * rng.range(0.7, 1.2),
          scale: rng.range(0.8, 1.3),
          drag: 0.25,
          spinRate: rng.range(-9, 9));
    }
  }

  void _spawnRing(double x, double y, double radius, Payload payload) {
    // The ring sprite is drawn at 30px across, so scale maps it to the real
    // radius of the effect.
    _spawnParticle('ring_${payloadDefs[payload]!.key}', x, y,
        life: 0.32, scale: radius / 15.0, drag: 1.0);
  }

  /// A visible line between two points, so instant vectors read as something
  /// happening rather than as nothing at all.
  void _spawnArc(double x1, double y1, double x2, double y2, Payload payload,
      {double life = 0.22, double width = 2.4}) {
    final a = arcPool.obtain(maxScan: 32);
    if (a == null) return;
    a.alive = true;
    a.x1 = x1;
    a.y1 = y1;
    a.x2 = x2;
    a.y2 = y2;
    a.life = life;
    a.maxLife = life;
    a.width = width;
    a.payload = payload;
  }

  void _updateArcs(double dt) {
    for (final a in arcs) {
      if (!a.alive) continue;
      a.life -= dt;
      if (a.life <= 0) a.alive = false;
    }
  }

  void _spawnBeamTrail(double x1, double y1, double x2, double y2, Payload payload) {
    final dx = x2 - x1, dy = y2 - y1;
    final dist = math.sqrt(dx * dx + dy * dy);
    final steps = (dist / 10).ceil().clamp(1, 24);
    final key = payloadDefs[payload]!.key;
    for (var i = 0; i <= steps; i++) {
      final t = i / steps;
      _spawnParticle('spark_$key', x1 + dx * t, y1 + dy * t,
          life: 0.2, scale: 1.2, drag: 0.1);
    }
  }

  void _updateParticles(double dt) {
    for (final p in particles) {
      if (!p.alive) continue;
      p.life -= dt;
      if (p.life <= 0) {
        p.alive = false;
        continue;
      }
      p.x += p.vx * dt;
      p.y += p.vy * dt;
      if (p.drag < 1.0) {
        final k = math.pow(p.drag, dt).toDouble();
        p.vx *= k;
        p.vy *= k;
      }
      p.spin += p.spinRate * dt;
    }
  }

  // --- spawning -----------------------------------------------------------

  void _updateSpawning(double dt) {
    final minutes = time / 60.0;

    _spawnTimer -= dt;
    final perSecond = 1.6 + minutes * 2.4;
    if (_spawnTimer <= 0) {
      _spawnTimer = 1.0 / perSecond;
      final batch = 1 + (minutes * 0.7).floor();
      for (var i = 0; i < batch; i++) {
        _spawnEnemy(_pickArchetype(minutes));
      }
    }

    if (time >= _nextEliteAt) {
      _nextEliteAt += 70;
      _spawnEnemy('elite');
    }
  }

  String _pickArchetype(double minutes) {
    // Weights ramp in over time so the swarm's composition keeps shifting and
    // the player's build has to keep answering new movement patterns.
    final weights = <String, double>{
      'mote': math.max(0.6, 5.0 - minutes * 0.7),
      'crawler': minutes < 0.4 ? 0 : 3.0,
      'spiker': minutes < 1.2 ? 0 : 2.2 + minutes * 0.2,
      'floater': minutes < 2.0 ? 0 : 1.6 + minutes * 0.15,
      'weaver': minutes < 3.0 ? 0 : 1.4 + minutes * 0.2,
      'brute': minutes < 4.0 ? 0 : 0.8 + minutes * 0.12,
    };
    final keys = weights.keys.toList();
    final idx = rng.weighted(keys.map((k) => weights[k]!).toList());
    return keys[idx];
  }

  void _spawnEnemy(String archetype) {
    final e = enemyPool.obtain();
    if (e == null) return;
    final def = enemyDefs[archetype]!;

    // Spawn on an ellipse matching the viewport rather than a circle. On a tall
    // phone screen a circle of radius max(w, h) puts side spawns twice as far
    // away as top spawns, so pressure arrives lopsidedly from above and below.
    const margin = 55.0;
    final ang = rng.range(0, math.pi * 2);
    final sx = px + math.cos(ang) * (viewHalfWidth + margin);
    final sy = py + math.sin(ang) * (viewHalfHeight + margin);

    final hpScale = 1.0 + time / 90.0;
    e.spawn(def, sx, sy, rng.rangeInt(0, 4), hpScale);
  }

  // --- adaptation ---------------------------------------------------------

  /// The swarm's counter-pressure.
  ///
  /// Periodically, whichever damage type has been doing the most work gains
  /// resistance and everything else decays back toward zero. Leaning on one
  /// payload forever is therefore self-defeating, which is what forces the
  /// player to keep breeding diversity rather than stacking a single lineage.
  void _updateAdaptation(double dt) {
    _adaptTimer -= dt;
    if (_adaptTimer > 0) return;
    _adaptTimer = adaptInterval;

    Payload? dominant;
    var best = 0.0;
    var total = 0.0;
    _damageByPayload.forEach((p, v) {
      total += v;
      if (v > best) {
        best = v;
        dominant = p;
      }
    });

    // Nothing meaningful happened this interval; let resistance decay.
    if (dominant == null || total < 1) {
      resistance.updateAll((_, v) => math.max(0, v - 0.04));
      return;
    }

    final share = best / total;
    // The harder the player leans on one payload, the faster the swarm adapts.
    final gain = 0.05 + share * 0.10;
    resistance[dominant!] = math.min(maxResistance, (resistance[dominant!] ?? 0) + gain);

    for (final p in Payload.values) {
      if (p != dominant) {
        resistance[p] = math.max(0, (resistance[p] ?? 0) - 0.035);
      }
    }

    // Partially forget history so a payload the player abandons stops being
    // counted as dominant within a couple of intervals.
    _damageByPayload.updateAll((_, v) => v * 0.3);

    if (share > 0.4) {
      lastAdaptedPayload = dominant;
      adaptNoticeTime = 3.0;
      onSound?.call('adapt');
    }
  }

  // --- level up -----------------------------------------------------------

  /// Adds a wild spore to an empty slot. Returns false when full.
  bool addAbility(Genome g) {
    if (abilities.length >= maxAbilitySlots) return false;
    abilities.add(Ability(g, _nextSlot++ % maxAbilitySlots));
    heldGenomes.add(g);
    return true;
  }

  /// Breeds two equipped abilities. Both parents are consumed and the child
  /// takes a single slot, trading breadth for depth.
  void spliceAbilities(Ability a, Ability b, Genome child) {
    _releaseSlot(a.slot);
    _releaseSlot(b.slot);
    abilities.remove(a);
    abilities.remove(b);
    abilities.add(Ability(child, a.slot));
    heldGenomes.add(child);
  }

  /// Swaps a new genome into an occupied slot, discarding what was there.
  void replaceAbility(Ability target, Genome g) {
    final i = abilities.indexOf(target);
    if (i < 0) return;
    _releaseSlot(target.slot);
    abilities[i] = Ability(g, target.slot);
    heldGenomes.add(g);
  }

  /// Deepest lineage reached this run, for the end-of-run summary.
  int get deepestGeneration =>
      heldGenomes.fold(0, (m, g) => g.generation > m ? g.generation : m);

  /// Kills any persistent shots belonging to a slot that is being reassigned,
  /// so a replaced ability does not leave orphaned orbits spinning forever.
  void _releaseSlot(int slot) {
    for (final s in shots) {
      if (s.alive && s.slot % maxAbilitySlots == slot) s.alive = false;
    }
    for (final e in enemies) {
      if (!e.alive) continue;
      e.hitCooldown[slot] = 0;
      e.hitCooldown[slot + maxAbilitySlots] = 0;
    }
  }

  // --- queries ------------------------------------------------------------

  Enemy? _nearest(double x, double y, double maxDist, {List<Enemy>? exclude}) {
    Enemy? best;
    var bestD2 = maxDist * maxDist;
    _hash.forEachNear(x, y, maxDist, (i) {
      final e = enemies[i];
      if (!e.alive) return;
      if (exclude != null && exclude.contains(e)) return;
      final dx = e.x - x, dy = e.y - y;
      final d2 = dx * dx + dy * dy;
      if (d2 < bestD2) {
        bestD2 = d2;
        best = e;
      }
    });
    return best;
  }

  static double _dist2(double ax, double ay, double bx, double by) {
    final dx = ax - bx, dy = ay - by;
    return dx * dx + dy * dy;
  }

  int get liveEnemies => enemyPool.liveCount;
}
