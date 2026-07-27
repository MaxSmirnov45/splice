import 'dart:math' as math;
import 'dart:typed_data';

import '../genome/genes.dart';

/// Maximum ability slots the player can hold at once.
///
/// Also the width of each enemy's per-ability hit-cooldown array, which is how
/// persistent vectors (orbit, aura, tether) are stopped from dealing damage
/// every single frame.
const int maxAbilitySlots = 6;

class EnemyDef {
  final String archetype;
  final double hp;
  final double speed;
  final double radius;
  final double contactDamage;
  final double xp;

  /// Steering flavour. See [EnemyBehaviour].
  final EnemyBehaviour behaviour;

  /// This archetype's ranged weapon, or null if it only threatens on contact.
  final RangedAttack? ranged;

  /// Whether this archetype is worth drawing a health bar over. Reserved for
  /// the heavy units; drawing one per swarm member costs more than it tells
  /// the player.
  final bool showsHealthBar;

  const EnemyDef(this.archetype,
      {required this.hp,
      required this.speed,
      required this.radius,
      required this.contactDamage,
      required this.xp,
      this.behaviour = EnemyBehaviour.chase,
      this.ranged,
      this.showsHealthBar = false});

  /// Sprite radius, derived from the generator's body size. Kept slightly
  /// tighter than the drawn sprite so glow never reads as a hitbox.
  double get spriteScale => 1.0;
}

enum EnemyBehaviour {
  /// Straight at the player.
  chase,

  /// Chases, but drifts sideways so groups fan out instead of stacking.
  weave,

  /// Keeps its distance and circles.
  orbit,

  /// Accelerates in bursts, pausing between lunges.
  lunge,

  /// Closes to its weapon's standoff distance and shoots from there, holding
  /// position entirely while winding up so the telegraph stays readable.
  gunner,
}

/// An enemy's ranged weapon.
///
/// Every field exists to keep incoming fire fair. [windup] is the telegraph
/// the player reacts to, [standoff] is where the shooter stops so it is never
/// firing from inside the melee scrum, and [shotSpeed] is deliberately well
/// under the player's own projectiles so a shot can be outrun.
class RangedAttack {
  final double damage;

  /// Maximum firing distance. Beyond this the shooter closes in.
  final double range;

  /// Distance it tries to hold while shooting.
  final double standoff;

  /// Seconds between volleys.
  final double interval;

  /// Seconds of visible telegraph before the volley leaves the muzzle.
  final double windup;

  final double shotSpeed;
  final double shotRadius;

  /// Projectiles per volley, spread evenly across [spread] radians.
  final int shots;
  final double spread;

  const RangedAttack({
    required this.damage,
    required this.range,
    required this.standoff,
    required this.interval,
    required this.windup,
    required this.shotSpeed,
    this.shotRadius = 7,
    this.shots = 1,
    this.spread = 0,
  });
}

const Map<String, EnemyDef> enemyDefs = {
  'mote': EnemyDef('mote',
      hp: 8, speed: 62, radius: 6.5, contactDamage: 4, xp: 1),
  'crawler': EnemyDef('crawler',
      hp: 22, speed: 48, radius: 9.5, contactDamage: 7, xp: 2,
      behaviour: EnemyBehaviour.weave),
  'spiker': EnemyDef('spiker',
      hp: 30, speed: 74, radius: 10.5, contactDamage: 11, xp: 3,
      behaviour: EnemyBehaviour.lunge),
  'floater': EnemyDef('floater',
      hp: 26, speed: 40, radius: 10.5, contactDamage: 6, xp: 3,
      behaviour: EnemyBehaviour.orbit),
  'brute': EnemyDef('brute',
      hp: 130, speed: 30, radius: 14, contactDamage: 18, xp: 9,
      showsHealthBar: true),
  'weaver': EnemyDef('weaver',
      hp: 64, speed: 56, radius: 12.5, contactDamage: 12, xp: 6,
      behaviour: EnemyBehaviour.weave),
  // Ranged. Stops well short and lobs a single slow, fat projectile. Its job
  // is to punish standing still, not to out-damage the melee swarm.
  'spitter': EnemyDef('spitter',
      hp: 34, speed: 40, radius: 10, contactDamage: 5, xp: 4,
      behaviour: EnemyBehaviour.gunner,
      ranged: RangedAttack(
          damage: 8,
          range: 250,
          standoff: 185,
          interval: 2.9,
          windup: 0.65,
          shotSpeed: 165)),
  // Ranged heavy. Fires a fan, so sidestepping is not automatically enough —
  // the player has to read which way the spread opens.
  'lancer': EnemyDef('lancer',
      hp: 95, speed: 30, radius: 13, contactDamage: 9, xp: 9,
      behaviour: EnemyBehaviour.gunner,
      showsHealthBar: true,
      ranged: RangedAttack(
          damage: 10,
          range: 330,
          standoff: 250,
          interval: 3.6,
          windup: 0.85,
          shotSpeed: 190,
          shotRadius: 8,
          shots: 3,
          spread: 0.44)),
  'elite': EnemyDef('elite',
      hp: 700, speed: 34, radius: 17.5, contactDamage: 26, xp: 60,
      behaviour: EnemyBehaviour.lunge, showsHealthBar: true),
};

/// One swarm member.
///
/// Plain mutable object reused from a pool. At the entity counts this game
/// targets, pooled objects are cheap; the expensive thing is draw calls, which
/// the sprite batch already collapses.
class Enemy {
  bool alive = false;

  double x = 0, y = 0;
  double vx = 0, vy = 0;
  double hp = 0, maxHp = 0;

  late EnemyDef def;
  int variant = 0;

  /// Seconds remaining on each status.
  double slowTime = 0, slowFactor = 1.0;
  double burnTime = 0, burnDps = 0;
  double corrodeTime = 0;
  double stunTime = 0;

  /// Which payload applied the current damage-over-time, for kill attribution
  /// and particle colour.
  Payload dotPayload = Payload.kinetic;

  /// Per-ability re-hit cooldowns. Persistent vectors check this so a
  /// lingering aura ticks at a sane cadence instead of every frame.
  ///
  /// Twice [maxAbilitySlots] wide: a hybrid's primary and secondary vectors
  /// need independent lockouts. Sharing one made hybrids sabotage themselves —
  /// a persistent secondary orbit re-armed the lockout every tick and the
  /// primary could never land a hit.
  final Float32List hitCooldown = Float32List(maxAbilitySlots * 2);

  /// Behaviour state: phase for weaving, timer for lunging.
  double phase = 0;
  double actionTimer = 0;

  /// Seconds until this enemy may begin its next volley.
  double fireTimer = 0;

  /// Seconds left in the visible wind-up. Zero means it is not charging.
  double windup = 0;

  /// Total length of the current wind-up, so the telegraph can show progress.
  double windupTotal = 0;

  /// Aim locked in when the wind-up began, normalised.
  ///
  /// Locked rather than tracked so the telegraph does not lie: the line the
  /// player sees during the wind-up is exactly where the volley will go, and
  /// stepping out of it is therefore a real dodge rather than a coin flip.
  double aimX = 1, aimY = 0;

  bool get charging => windup > 0;

  /// Set on hit, drives the white damage flash.
  double flash = 0;

  double get radius => def.radius;

  void spawn(EnemyDef d, double sx, double sy, int variantIndex, double hpScale) {
    alive = true;
    def = d;
    x = sx;
    y = sy;
    vx = vy = 0;
    maxHp = d.hp * hpScale;
    hp = maxHp;
    variant = variantIndex;
    slowTime = 0;
    slowFactor = 1.0;
    burnTime = 0;
    burnDps = 0;
    corrodeTime = 0;
    stunTime = 0;
    flash = 0;
    phase = 0;
    actionTimer = 0;
    // Staggered so a wave that spawns together does not fire in unison.
    fireTimer = d.ranged == null ? 0 : d.ranged!.interval * 0.5;
    windup = 0;
    windupTotal = 0;
    aimX = 1;
    aimY = 0;
    for (var i = 0; i < hitCooldown.length; i++) {
      hitCooldown[i] = 0;
    }
  }
}

/// How a [Shot] behaves once it exists.
enum ShotKind {
  /// Travels in a straight line.
  bolt,

  /// Travels toward the nearest enemy, steering as it goes.
  seeker,

  /// Circles the player at a fixed radius.
  orbit,

  /// Sits where it was dropped.
  mine,

  /// Expands outward from where it was created.
  wave,
}

/// A damaging entity in the world.
///
/// Instant vectors (aura, beam, burst, chain, tether) do not create shots —
/// they resolve damage immediately and spawn particles for the visual. Only
/// vectors that persist in space need an entity.
class Shot {
  bool alive = false;

  double x = 0, y = 0;
  double vx = 0, vy = 0;
  double life = 0;
  double radius = 4;

  late ShotKind kind;
  late Payload payload;

  double damage = 0;
  double knockback = 0;
  double seek = 0;

  /// Remaining enemies this shot may hit. -1 is unlimited.
  int pierce = 0;

  /// Which ability slot fired this, for the per-enemy hit cooldown.
  int slot = 0;

  /// Orbit only: angular position and distance from the player.
  double angle = 0, orbitRadius = 0, angularSpeed = 0;

  /// Wave only: current and maximum radius.
  double waveRadius = 0, waveMax = 0;

  /// Rotation used purely for rendering.
  double spin = 0;

  double statusDuration = 0;
  double dotPerSecond = 0;
}

/// XP motes and health drops.
class Pickup {
  bool alive = false;
  double x = 0, y = 0;

  /// Scatter velocity, used only before the pickup is attracted.
  double vx = 0, vy = 0;

  double value = 0;
  bool isHealth = false;

  /// Set once the pickup is inside magnet range and homing to the player.
  bool attracted = false;

  /// Homing speed once attracted.
  ///
  /// Attraction steers the pickup directly rather than accumulating force.
  /// Applying acceleration toward a moving target produces an orbit: the mote
  /// builds sideways velocity, sails past, and circles instead of arriving.
  double homeSpeed = 0;
}

/// A drawn line between two points: chain jumps and beam sweeps.
///
/// These vectors resolve their damage instantly, so without an explicit visual
/// the only feedback is a few spark particles — which at a wide zoom reads as
/// the ability doing nothing at all.
class Arc {
  bool alive = false;
  double x1 = 0, y1 = 0, x2 = 0, y2 = 0;
  double life = 0, maxLife = 0;
  double width = 2;
  late Payload payload;
}

/// Purely cosmetic. Never affects simulation, so it can be culled freely under
/// load without changing outcomes.
class Particle {
  bool alive = false;
  double x = 0, y = 0;
  double vx = 0, vy = 0;
  double life = 0, maxLife = 0;
  double scale = 1;
  double spin = 0, spinRate = 0;
  int color = 0xFFFFFFFF;
  String frame = 'dot_white';

  /// Multiplies velocity each second; below 1 the particle eases to a stop.
  double drag = 1.0;
}

/// Fixed-size recycling pool.
///
/// Entities are never allocated during play; [obtain] hands back a dead slot
/// and returns null once the cap is reached. Refusing to grow is deliberate:
/// it puts a hard ceiling on worst-case frame cost.
class Pool<T> {
  final List<T> items;
  final bool Function(T) isAlive;
  int _cursor = 0;

  Pool(int capacity, T Function() create, this.isAlive)
      : items = List<T>.generate(capacity, (_) => create(), growable: false);

  int get capacity => items.length;

  /// Hands back a dead slot, or null if none was found.
  ///
  /// [maxScan] bounds how many slots are examined. This matters enormously for
  /// a saturated pool: without a bound, every failed spawn walks the entire
  /// pool before returning null, so a full 700-particle pool being hit with
  /// hundreds of spawn attempts per second burns hundreds of thousands of
  /// iterations a second achieving nothing. Cosmetic pools should pass a small
  /// bound and accept the occasional missed particle.
  T? obtain({int? maxScan}) {
    // Resume scanning where the last search ended; with a mostly-full pool
    // this finds a free slot far faster than always restarting at zero.
    final limit = maxScan == null ? items.length : math.min(maxScan, items.length);
    for (var i = 0; i < limit; i++) {
      final idx = (_cursor + i) % items.length;
      if (!isAlive(items[idx])) {
        _cursor = (idx + 1) % items.length;
        return items[idx];
      }
    }
    return null;
  }

  int get liveCount {
    var n = 0;
    for (final it in items) {
      if (isAlive(it)) n++;
    }
    return n;
  }
}

/// A projectile fired by an enemy.
///
/// A separate type from [Shot] rather than a flag on it. The two never share
/// code paths — enemy fire cannot crit, leech, pierce, apply status or trigger
/// anything — and keeping them apart means no player-side effect can ever be
/// applied to incoming fire by accident.
class Threat {
  bool alive = false;

  double x = 0, y = 0;
  double vx = 0, vy = 0;
  double damage = 0;
  double radius = 7;

  /// Seconds before it expires on its own, so a stray shot cannot travel the
  /// whole map and hit the player a screen later.
  double life = 0;

  /// Rotation for rendering, and the countdown between trail motes.
  double spin = 0;
  double trailTimer = 0;

  void spawn(double sx, double sy, double dx, double dy, RangedAttack w) {
    alive = true;
    x = sx;
    y = sy;
    vx = dx * w.shotSpeed;
    vy = dy * w.shotSpeed;
    damage = w.damage;
    radius = w.shotRadius;
    life = w.range / w.shotSpeed + 0.5;
    spin = 0;
    trailTimer = 0;
  }
}
