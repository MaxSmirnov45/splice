/// Gene definitions.
///
/// An ability is a genome with four slots: one Vector (how it reaches an
/// enemy), one Payload (what it does on contact), one Trigger (what makes it
/// fire), and any number of Riders (stacking modifiers with no cap). The Rider
/// slot is what makes evolution open-ended — the other three are finite sets,
/// but rider stacks and their interactions are not.
library;

/// How the ability delivers itself.
enum Vector { bolt, orbit, aura, beam, mine, burst, chain, tether, wave, swarm }

/// What the ability does on contact.
enum Payload { kinetic, burn, frost, corrode, shock, bleed, voidp }

/// What causes the ability to fire.
enum Trigger { timer, onKill, onHurt, onMove, onStill, onCrit, onLowHp, onDodge }

/// Stacking modifiers. Counts are unbounded.
enum Rider {
  amplify, // raw damage
  rapid, // fire rate
  split, // extra instances per activation
  pierce, // pass through more enemies
  seek, // homing strength
  reach, // range, radius, projectile size
  weight, // knockback and stagger
  ferment, // status effect duration
  bloom, // chance to spawn a child effect on kill
  leech, // lifesteal
  echo, // chance to fire a second time immediately
  greed, // xp gain from kills this ability lands
}

class VectorDef {
  final String name;

  /// Damage per hit before payload and rider scaling.
  final double damage;

  /// Seconds between activations at zero `rapid`.
  final double cooldown;

  /// World units per second. Zero for stationary vectors.
  final double speed;

  /// Effective radius or length, depending on the vector.
  final double range;

  /// Seconds an instance survives. Zero means "until it hits something".
  final double life;

  /// Instances produced per activation before `split`.
  final int count;

  /// How many enemies one instance can hit before expiring. -1 is unlimited.
  final int pierce;

  /// Multiplies how strongly `split` adds instances. Vectors that already
  /// cover a wide area gain less from it.
  final double splitAffinity;

  const VectorDef(this.name,
      {required this.damage,
      required this.cooldown,
      required this.speed,
      required this.range,
      required this.life,
      required this.count,
      required this.pierce,
      this.splitAffinity = 1.0});
}

const Map<Vector, VectorDef> vectorDefs = {
  // Bread and butter: a projectile at the nearest target.
  Vector.bolt: VectorDef('Bolt',
      damage: 10, cooldown: 0.85, speed: 300, range: 320, life: 1.6, count: 1, pierce: 0),
  // Satellites. Constant uptime, no aiming, rewards standing in the swarm.
  //
  // Radius deliberately tight. Enemies chase until they are touching the
  // player, so a wide orbit sweeps empty space over their heads and only
  // clips them on the way in — which reads as the ability being broken.
  Vector.orbit: VectorDef('Orbit',
      damage: 7,
      cooldown: 0.55,
      speed: 2.4,
      range: 34,
      life: 0,
      count: 2,
      pierce: -1,
      splitAffinity: 1.4),
  // Persistent field centred on the player. Low damage, total coverage.
  Vector.aura: VectorDef('Aura',
      damage: 4.5,
      cooldown: 0.42,
      speed: 0,
      range: 74,
      life: 0,
      count: 1,
      pierce: -1,
      splitAffinity: 0.35),
  // Long piercing line. Excellent into rows, poor into scattered targets.
  Vector.beam: VectorDef('Beam',
      damage: 16,
      cooldown: 1.5,
      speed: 0,
      range: 340,
      life: 0.28,
      count: 1,
      pierce: -1,
      splitAffinity: 0.7),
  // Dropped hazard. Rewards kiting through your own trail.
  Vector.mine: VectorDef('Mine',
      damage: 26, cooldown: 1.9, speed: 0, range: 46, life: 7.0, count: 1, pierce: 2),
  // Radial nova from the player. Panic button on a timer.
  Vector.burst: VectorDef('Burst',
      damage: 14,
      cooldown: 2.4,
      speed: 0,
      range: 118,
      life: 0.22,
      count: 1,
      pierce: -1,
      splitAffinity: 0.4),
  // Jumps between targets. Scales with crowd density.
  Vector.chain: VectorDef('Chain',
      damage: 9, cooldown: 1.25, speed: 900, range: 150, life: 0.3, count: 1, pierce: 3),
  // Attaches to a target and grinds it while it lives.
  Vector.tether: VectorDef('Tether',
      damage: 5.5, cooldown: 0.3, speed: 0, range: 130, life: 0, count: 1, pierce: 0),
  // Expanding ring that leaves the player behind.
  Vector.wave: VectorDef('Wave',
      damage: 12,
      cooldown: 2.0,
      speed: 210,
      range: 200,
      life: 1.4,
      count: 1,
      pierce: -1,
      splitAffinity: 0.5),
  // Homing seekers with short life. Weak alone, brutal when split.
  Vector.swarm: VectorDef('Swarm',
      damage: 6,
      cooldown: 1.1,
      speed: 190,
      range: 280,
      life: 2.6,
      count: 3,
      pierce: 0,
      splitAffinity: 1.5),
};

class PayloadDef {
  final String name;

  /// Atlas key for effect sprites and the colour this damage type reads as.
  final String key;

  /// Multiplies the vector's base damage. Payloads with strong side effects
  /// pay for them here.
  final double damageMul;

  /// Fraction of the hit applied again per second as a lingering effect.
  final double dotPerSecond;

  /// Seconds the status lasts before `ferment`.
  final double statusDuration;

  const PayloadDef(this.name, this.key,
      {required this.damageMul, this.dotPerSecond = 0, this.statusDuration = 0});
}

const Map<Payload, PayloadDef> payloadDefs = {
  // Pure numbers, no rider. The baseline every other payload is priced against.
  Payload.kinetic: PayloadDef('Kinetic', 'kinetic', damageMul: 1.15),
  // Damage over time that rewards wide, frequent, low-damage application.
  Payload.burn: PayloadDef('Burn', 'burn',
      damageMul: 0.72, dotPerSecond: 0.55, statusDuration: 3.0),
  // Slows targets. Defensive payload; the damage is secondary.
  Payload.frost: PayloadDef('Frost', 'frost', damageMul: 0.8, statusDuration: 2.2),
  // Strips enemy resistance, which is the direct counter to swarm adaptation.
  Payload.corrode: PayloadDef('Corrode', 'corrode', damageMul: 0.7, statusDuration: 4.5),
  // Arcs to a nearby target and briefly staggers.
  Payload.shock: PayloadDef('Shock', 'shock', damageMul: 0.85, statusDuration: 0.4),
  // Scales with how fast the target is moving — punishes the fast swarm.
  Payload.bleed: PayloadDef('Bleed', 'bleed',
      damageMul: 0.78, dotPerSecond: 0.45, statusDuration: 3.5),
  // Ignores resistance entirely, at a low base. The escape valve when the
  // swarm has adapted hard against everything else.
  Payload.voidp: PayloadDef('Void', 'void', damageMul: 0.6),
};

class TriggerDef {
  final String name;

  /// Multiplies damage. Situational triggers hit harder to compensate for
  /// firing less predictably.
  final double damageMul;

  /// Multiplies cooldown. `timer` is 1.0; event triggers use their own gating.
  final double cooldownMul;

  /// True when the ability fires from an event rather than a running clock.
  final bool eventDriven;

  const TriggerDef(this.name,
      {this.damageMul = 1.0, this.cooldownMul = 1.0, this.eventDriven = false});
}

const Map<Trigger, TriggerDef> triggerDefs = {
  Trigger.timer: TriggerDef('Timed'),
  // Fires on enemy death. Snowballs in dense waves, dead weight when starved.
  Trigger.onKill: TriggerDef('On Kill',
      damageMul: 0.62, cooldownMul: 0.25, eventDriven: true),
  // Fires when the player is hit. Turns damage taken into a counterattack.
  Trigger.onHurt: TriggerDef('On Hurt',
      damageMul: 2.4, cooldownMul: 0.5, eventDriven: true),
  // Fires faster the faster the player moves. Rewards constant kiting.
  Trigger.onMove: TriggerDef('While Moving', damageMul: 0.9, cooldownMul: 0.8),
  // Fires only while standing still. High risk in a swarm, high reward.
  Trigger.onStill: TriggerDef('While Still', damageMul: 1.6, cooldownMul: 0.7),
  // Fires on a critical hit from any source.
  Trigger.onCrit: TriggerDef('On Crit',
      damageMul: 1.35, cooldownMul: 0.4, eventDriven: true),
  // Fires only below a third health. A desperation gene.
  Trigger.onLowHp: TriggerDef('While Wounded', damageMul: 2.0, cooldownMul: 0.6),
  // Fires when an enemy attack just misses.
  Trigger.onDodge: TriggerDef('On Dodge',
      damageMul: 1.5, cooldownMul: 0.35, eventDriven: true),
};

class RiderDef {
  final String name;

  /// Effect of a single stack. Interpretation depends on the rider; see [Genome].
  final double perStack;

  /// Growth exponent: effect = perStack * count^exponent.
  ///
  /// Deliberately sublinear rather than a converging series. A geometric
  /// falloff would impose a hard ceiling on every rider, which would make late
  /// generations pointless; this keeps growth unbounded but decelerating, so
  /// stacking one rider forever always helps and never trivialises the game.
  final double exponent;

  const RiderDef(this.name, {required this.perStack, this.exponent = 0.88});
}

const Map<Rider, RiderDef> riderDefs = {
  Rider.amplify: RiderDef('Amplify', perStack: 0.34),
  Rider.rapid: RiderDef('Rapid', perStack: 0.26),
  Rider.split: RiderDef('Split', perStack: 1.0, exponent: 0.62),
  Rider.pierce: RiderDef('Pierce', perStack: 1.0, exponent: 0.80),
  Rider.seek: RiderDef('Seek', perStack: 0.55),
  Rider.reach: RiderDef('Reach', perStack: 0.20),
  Rider.weight: RiderDef('Weight', perStack: 0.45),
  Rider.ferment: RiderDef('Ferment', perStack: 0.30),
  // Chance-based riders use a low exponent and are clamped below 1.0 when
  // applied, so they approach certainty without ever reaching it.
  Rider.bloom: RiderDef('Bloom', perStack: 0.14, exponent: 0.55),
  Rider.leech: RiderDef('Leech', perStack: 0.02, exponent: 0.70),
  Rider.echo: RiderDef('Echo', perStack: 0.16, exponent: 0.52),
  Rider.greed: RiderDef('Greed', perStack: 0.18),
};

/// Adjectives used when naming a spliced ability, indexed by payload.
const Map<Payload, String> payloadAdjective = {
  Payload.kinetic: 'Blunt',
  Payload.burn: 'Smouldering',
  Payload.frost: 'Rimed',
  Payload.corrode: 'Caustic',
  Payload.shock: 'Arcing',
  Payload.bleed: 'Rending',
  Payload.voidp: 'Hollow',
};
