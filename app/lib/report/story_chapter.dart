import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../api.dart' show plausibleWallClock;
import 'report_card.dart';
import 'story_model.dart';

const storyInk = Color(0xFFF7F8FA);
const storyAccent = Color(0xFFFF5E7A);
const storyPaper = Color(0xFF080A0D);
const storySurface = Color(0xFF141820);
const storyMuted = Color(0xFF8A929E);

class StoryChapterView extends StatelessWidget {
  const StoryChapterView({
    super.key,
    required this.chapter,
    required this.model,
    required this.assets,
    required this.personal,
    required this.index,
    required this.revealed,
    this.exporting = false,
    this.minHeight = 560,
  });

  final StoryChapter chapter;
  final StoryModel model;
  final ReportCardAssets assets;
  final bool personal, revealed, exporting;
  final int index;
  final double minHeight;

  @override
  Widget build(BuildContext context) {
    final opening = chapter.kind == StoryChapterKind.opening;
    final closing = chapter.kind == StoryChapterKind.closing;
    final colors = [
      const [Color(0xFF080A0D), Color(0xFF171018)],
      const [Color(0xFF0B0E12), Color(0xFF11151B)],
      const [Color(0xFF0B0D11), Color(0xFF18131A)],
      const [Color(0xFF0D1015), Color(0xFF101820)],
      const [Color(0xFF0A0C10), Color(0xFF171116)],
      const [Color(0xFF090B0E), Color(0xFF12151A)],
    ][index % 6];
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: colors,
        ),
      ),
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: minHeight),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(22, 38, 22, 38),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _motion(
                context,
                0,
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        chapter.eyebrow,
                        style: const TextStyle(
                          color: storyAccent,
                          fontSize: 11,
                          letterSpacing: 1.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      (index + 1).toString().padLeft(2, '0'),
                      style: const TextStyle(
                        color: Colors.white30,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 22),
              _motion(
                context,
                1,
                Text(
                  chapter.title,
                  style: TextStyle(
                    color: storyInk,
                    fontSize: opening ? 43 : 32,
                    height: 1.16,
                    fontWeight: FontWeight.w900,
                    letterSpacing: -1.1,
                  ),
                ),
              ),
              if (opening) ...[
                const SizedBox(height: 16),
                _motion(
                  context,
                  2,
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 13,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: .08),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      model.day.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        letterSpacing: 1.2,
                      ),
                    ),
                  ),
                ),
              ],
              if (chapter.body.isNotEmpty) ...[
                const SizedBox(height: 14),
                _motion(
                  context,
                  2,
                  Text(
                    chapter.body,
                    style: const TextStyle(
                      fontSize: 13,
                      color: storyMuted,
                      height: 1.55,
                    ),
                  ),
                ),
              ],
              if (chapter.number case final count?) ...[
                const SizedBox(height: 18),
                _motion(context, 2, _number(context, count)),
                Text(
                  chapter.unit,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
              if (chapter.kind == StoryChapterKind.moments &&
                  chapter.photoIds.isNotEmpty) ...[
                const SizedBox(height: 24),
                _photoWall(context, chapter.photoIds, animationBase: 3),
              ],
              if (chapter.metrics.isNotEmpty) ...[
                const SizedBox(height: 24),
                _metricCards(context),
              ],
              if (chapter.kind == StoryChapterKind.connections &&
                  chapter.people.isNotEmpty) ...[
                const SizedBox(height: 24),
                _relationshipNetwork(context),
              ],
              if (chapter.kind == StoryChapterKind.contributors) ...[
                const SizedBox(height: 24),
                for (var i = 0; i < chapter.people.take(7).length; i++)
                  _motion(context, i + 2, _contributor(chapter.people[i])),
              ],
              if (chapter.photoIds.isNotEmpty &&
                  chapter.kind != StoryChapterKind.moments) ...[
                const SizedBox(height: 26),
                if (opening)
                  _motion(
                    context,
                    3,
                    Transform.rotate(
                      angle: -.018,
                      child: _photo(chapter.photoIds.first, 268, radius: 22),
                    ),
                  )
                else
                  _photoWall(context, chapter.photoIds, animationBase: 3),
              ],
              if (closing) ...[
                const SizedBox(height: 28),
                Container(height: 1, color: Colors.white12),
                const SizedBox(height: 18),
                Text(
                  '更新于 ${_generatedLabel()}',
                  style: const TextStyle(fontSize: 10, color: Colors.white38),
                ),
                const SizedBox(height: 22),
                const Text(
                  '团 图  /  把一起的日子，留在一起',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white70,
                    letterSpacing: 1,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  String _generatedLabel() {
    final value = storyInt(model.snapshot.raw['generated_at']);
    if (plausibleWallClock(value) == null) return '';
    final date = DateTime.fromMillisecondsSinceEpoch(value * 1000).toLocal();
    return '${date.year}.${date.month}.${date.day} '
        '${date.hour.toString().padLeft(2, '0')}:${date.minute.toString().padLeft(2, '0')}';
  }

  Widget _motion(BuildContext context, int order, Widget child) {
    if (exporting || MediaQuery.disableAnimationsOf(context)) return child;
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: revealed ? 1 : 0),
      duration: Duration(milliseconds: 520 + math.min(order, 6) * 85),
      curve: Curves.easeOutCubic,
      child: child,
      builder: (_, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 24 * (1 - value)),
          child: Transform.scale(
            scale: .965 + .035 * value,
            alignment: Alignment.center,
            child: child,
          ),
        ),
      ),
    );
  }

  Widget _number(BuildContext context, int count) {
    Widget text(int n) => Text(
          '$n',
          style: const TextStyle(
            color: storyAccent,
            fontSize: 100,
            height: 1,
            fontWeight: FontWeight.w900,
            letterSpacing: -5,
          ),
        );
    if (exporting || MediaQuery.disableAnimationsOf(context)) {
      return text(count);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: revealed ? count.toDouble() : 0),
      duration: const Duration(milliseconds: 1050),
      curve: Curves.easeOutQuart,
      builder: (_, value, __) => text(value.round()),
    );
  }

  Widget _metricCards(BuildContext context) => Wrap(
        spacing: 9,
        runSpacing: 9,
        children: [
          for (var i = 0; i < chapter.metrics.length; i++)
            _motion(
              context,
              i + 4,
              Container(
                constraints: const BoxConstraints(minWidth: 94),
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: .07),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: Colors.white10),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${chapter.metrics[i].value}',
                      style: const TextStyle(
                        fontSize: 25,
                        fontWeight: FontWeight.w800,
                        color: storyInk,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      chapter.metrics[i].label,
                      style: const TextStyle(fontSize: 10, color: storyMuted),
                    ),
                  ],
                ),
              ),
            ),
        ],
      );

  Widget _photo(int id, double height, {double radius = 14}) {
    final image = assets.photo(id);
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: SizedBox(
        width: double.infinity,
        height: height,
        child: image != null
            ? RawImage(image: image, fit: BoxFit.cover)
            : const ColoredBox(
                color: Color(0xFF20252D),
                child: Center(
                  child: Icon(Icons.photo_outlined, color: Colors.white24),
                ),
              ),
      ),
    );
  }

  Widget _photoWall(
    BuildContext context,
    List<int> source, {
    bool compact = false,
    int animationBase = 0,
  }) {
    final ids = source.take(compact ? 6 : 12).toList();
    if (ids.isEmpty) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (_, box) {
        final gap = compact ? 5.0 : 7.0;
        final heroHeight = compact ? 158.0 : 246.0;
        final tileHeight = compact ? 92.0 : 124.0;
        if (ids.length == 1) {
          return _motion(context, animationBase, _photo(ids.first, heroHeight));
        }
        if (ids.length == 2) {
          return _motion(
            context,
            animationBase,
            SizedBox(
              height: tileHeight * 1.35,
              child: Row(
                children: [
                  Expanded(child: _photo(ids[0], tileHeight * 1.35)),
                  SizedBox(width: gap),
                  Expanded(child: _photo(ids[1], tileHeight * 1.35)),
                ],
              ),
            ),
          );
        }
        final children = <Widget>[];
        var cursor = 0;
        if (ids.length >= 3) {
          children.add(
            _motion(
              context,
              animationBase,
              SizedBox(
                height: heroHeight,
                child: Row(
                  children: [
                    Expanded(flex: 2, child: _photo(ids[0], heroHeight)),
                    SizedBox(width: gap),
                    Expanded(
                      child: Column(
                        children: [
                          _photo(ids[1], (heroHeight - gap) / 2),
                          SizedBox(height: gap),
                          _photo(ids[2], (heroHeight - gap) / 2),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
          cursor = 3;
        }
        for (var row = 0; cursor < ids.length; row++) {
          final rowIds = ids.skip(cursor).take(3).toList();
          children.add(
            Padding(
              padding: EdgeInsets.only(top: gap),
              child: _motion(
                context,
                animationBase + row + 1,
                SizedBox(
                  height: tileHeight,
                  child: Row(
                    children: [
                      for (var i = 0; i < rowIds.length; i++) ...[
                        if (i > 0) SizedBox(width: gap),
                        Expanded(
                          flex: row.isEven && i == rowIds.length - 1 ? 2 : 1,
                          child: _photo(rowIds[i], tileHeight),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          );
          cursor += rowIds.length;
        }
        return Column(children: children);
      },
    );
  }

  Widget _avatar(StoryPerson person, [double size = 52]) {
    final image = assets.avatar(person.cover);
    return Container(
      width: size,
      height: size,
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(
          colors: [storyAccent, Color(0xFFFFB36B)],
        ),
        boxShadow: [
          BoxShadow(
            color: storyAccent.withValues(alpha: .22),
            blurRadius: 14,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipOval(
        child: image != null
            ? RawImage(image: image, fit: BoxFit.cover)
            : ColoredBox(
                color: const Color(0xFF252A33),
                child: Center(
                  child: Text(
                    person.name.isEmpty ? '友' : person.name.characters.first,
                    style: TextStyle(
                      fontSize: size * .36,
                      color: storyInk,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _pairedAvatars(StoryPerson partner) => SizedBox(
        width: 78,
        height: 50,
        child: Stack(
          children: [
            Positioned(left: 0, child: _avatar(model.selfPerson, 48)),
            Positioned(left: 30, child: _avatar(partner, 48)),
          ],
        ),
      );

  Widget _relationshipNetwork(BuildContext context) => _RelationshipNetwork(
        people: chapter.people,
        links: chapter.links,
        centerPerson: personal ? model.selfPerson : null,
        revealed: revealed,
        exporting: exporting,
        avatarBuilder: _avatar,
        detailBuilder: (person) => _selectedPersonCard(context, person),
      );

  Widget _selectedPersonCard(BuildContext context, StoryPerson person) =>
      Container(
        width: double.infinity,
        padding: const EdgeInsets.all(13),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: .055),
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (personal) _pairedAvatars(person) else _avatar(person, 50),
                const SizedBox(width: 9),
                Expanded(
                  child: Text(
                    person.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: storyInk,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  '${person.count}',
                  style: const TextStyle(
                    color: storyAccent,
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
            if (person.photoIds.isNotEmpty) ...[
              const SizedBox(height: 12),
              _photoWall(
                context,
                person.photoIds,
                compact: true,
                animationBase: 2,
              ),
            ],
          ],
        ),
      );

  Widget _contributor(StoryPerson person) {
    final maxCount = chapter.people.fold<int>(
      1,
      (n, p) => math.max(n, p.count),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Row(
        children: [
          _avatar(person, 36),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        person.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: storyInk,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    Text(
                      '${person.count}',
                      style: const TextStyle(
                        color: storyAccent,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 7),
                ClipRRect(
                  borderRadius: BorderRadius.circular(99),
                  child: LinearProgressIndicator(
                    minHeight: 4,
                    value: person.count / maxCount,
                    color: storyAccent,
                    backgroundColor: Colors.white10,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RelationshipNetwork extends StatefulWidget {
  const _RelationshipNetwork({
    required this.people,
    required this.links,
    required this.centerPerson,
    required this.revealed,
    required this.exporting,
    required this.avatarBuilder,
    required this.detailBuilder,
  });

  final List<StoryPerson> people;
  final List<StoryLink> links;
  final StoryPerson? centerPerson;
  final bool revealed;
  final bool exporting;
  final Widget Function(StoryPerson person, double size) avatarBuilder;
  final Widget Function(StoryPerson person) detailBuilder;

  @override
  State<_RelationshipNetwork> createState() => _RelationshipNetworkState();
}

class _RelationshipNetworkState extends State<_RelationshipNetwork>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  final Map<int, _XpbdParticle> _particles = {};
  final List<_XpbdDistanceConstraint> _constraints = [];
  int? _selectedId;
  int? _centerId;
  List<int> _orbitIds = const [];
  String _layoutSignature = '';
  Duration? _lastTick;
  Offset _middle = Offset.zero;
  double _radiusX = 0;
  double _radiusY = 0;
  double _yaw = 0;
  double _angularVelocity = 0;
  int _calmFrames = 0;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_step);
  }

  @override
  void didUpdateWidget(covariant _RelationshipNetwork oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.revealed && !oldWidget.revealed) _wake();
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  void _drag(double delta) {
    if (widget.exporting) return;
    _yaw += delta / 115;
    _angularVelocity = 0;
    _updateTargets();
    _wake();
    setState(() {});
  }

  void _release(double velocity) {
    if (widget.exporting) return;
    _angularVelocity = (velocity / 680).clamp(-3.2, 3.2);
    _wake();
  }

  void _toggle(StoryPerson person) {
    if (person.photoIds.isEmpty || widget.exporting) return;
    setState(() {
      _selectedId = _selectedId == person.personId ? null : person.personId;
    });
  }

  @override
  Widget build(BuildContext context) {
    final visiblePeople = widget.people.take(8).toList();
    final center = widget.centerPerson ?? visiblePeople.first;
    final orbit = widget.centerPerson == null
        ? visiblePeople.skip(1).toList()
        : visiblePeople;
    StoryPerson? selected;
    for (final person in visiblePeople) {
      if (person.personId == _selectedId) selected = person;
    }
    return Column(
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onHorizontalDragUpdate: (event) => _drag(event.delta.dx),
          onHorizontalDragEnd: (event) =>
              _release(event.velocity.pixelsPerSecond.dx),
          child: LayoutBuilder(
            builder: (_, box) => _network(box.maxWidth, center, orbit),
          ),
        ),
        AnimatedSize(
          duration: const Duration(milliseconds: 420),
          curve: Curves.easeOutCubic,
          child: selected == null
              ? const SizedBox(width: double.infinity)
              : Padding(
                  key: ValueKey('relationship-detail-${selected.personId}'),
                  padding: const EdgeInsets.only(top: 12),
                  child: widget.detailBuilder(selected),
                ),
        ),
      ],
    );
  }

  Widget _network(double width, StoryPerson center, List<StoryPerson> orbit) {
    const height = 310.0;
    final middle = Offset(width / 2, height / 2 - 2);
    final radiusX = math.max(52.0, (width - 88) / 2);
    const radiusY = 92.0;
    _ensureSimulation(width, center, orbit, middle, radiusX, radiusY);
    _updateTargets();
    final positions = <int, Offset>{
      for (final entry in _particles.entries)
        entry.key: widget.exporting ? entry.value.target : entry.value.position,
    };
    final depths = <int, double>{};
    if (center.personId != null) {
      depths[center.personId!] = 1;
    }
    for (var i = 0; i < orbit.length; i++) {
      final step = orbit.length == 2
          ? math.pi * 2 / 3
          : math.pi * 2 / math.max(1, orbit.length);
      final angle = _yaw + i * step - math.pi / 2;
      final depth = (math.sin(angle) + 1) / 2;
      final id = orbit[i].personId;
      if (id == null) continue;
      depths[id] = depth;
    }
    final ordered = [...orbit]..sort(
        (a, b) => (depths[a.personId] ?? 0).compareTo(depths[b.personId] ?? 0),
      );
    return SizedBox(
      height: height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned.fill(
            child: CustomPaint(
              painter: _RelationshipPainter(
                positions: positions,
                links: widget.links,
                spread: widget.exporting || widget.revealed ? 1 : 0,
                center: middle,
                radiusX: radiusX,
                radiusY: radiusY,
              ),
            ),
          ),
          _node(center, middle, 1, widget.centerPerson == null),
          for (final person in ordered)
            if (positions[person.personId] case final position?)
              _node(
                person,
                position,
                .76 + (depths[person.personId] ?? 0) * .28,
                true,
              ),
        ],
      ),
    );
  }

  void _ensureSimulation(
    double width,
    StoryPerson center,
    List<StoryPerson> orbit,
    Offset middle,
    double radiusX,
    double radiusY,
  ) {
    final centerId = center.personId;
    if (centerId == null) return;
    final orbitIds = [
      for (final person in orbit)
        if (person.personId != null) person.personId!,
    ];
    final signature =
        '${width.toStringAsFixed(1)}:$centerId:${orbitIds.join(',')}';
    _middle = middle;
    _radiusX = radiusX;
    _radiusY = radiusY;
    _centerId = centerId;
    _orbitIds = orbitIds;
    if (_layoutSignature == signature) return;
    _layoutSignature = signature;
    _particles
      ..clear()
      ..[centerId] = _XpbdParticle.pinned(middle);
    for (var i = 0; i < orbitIds.length; i++) {
      final seed = Offset((i.isEven ? 1 : -1) * .5, i * .35);
      _particles[orbitIds[i]] = _XpbdParticle(middle + seed);
    }
    _constraints.clear();
    final visible = _particles.keys.toSet();
    for (final link in widget.links) {
      if (!visible.contains(link.a) || !visible.contains(link.b)) continue;
      _constraints.add(
        _XpbdDistanceConstraint(
          link.a,
          link.b,
          restLength: link.a == centerId || link.b == centerId ? 116 : 142,
          compliance: .00008,
        ),
      );
    }
    _updateTargets();
    if (widget.exporting) {
      for (final particle in _particles.values) {
        particle
          ..position = particle.target
          ..previous = particle.target;
      }
    } else if (widget.revealed) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _wake());
    }
  }

  void _updateTargets() {
    final centerId = _centerId;
    if (centerId == null || !_particles.containsKey(centerId)) return;
    _particles[centerId]!.target = _middle;
    for (var i = 0; i < _orbitIds.length; i++) {
      final step = _orbitIds.length == 2
          ? math.pi * 2 / 3
          : math.pi * 2 / math.max(1, _orbitIds.length);
      final angle = _yaw + i * step - math.pi / 2;
      _particles[_orbitIds[i]]!.target = Offset(
        _middle.dx + math.cos(angle) * _radiusX,
        _middle.dy + math.sin(angle) * _radiusY,
      );
    }
  }

  void _wake() {
    if (!mounted || widget.exporting || !widget.revealed) return;
    _calmFrames = 0;
    _lastTick = null;
    if (!_ticker.isActive) _ticker.start();
  }

  void _step(Duration elapsed) {
    if (!mounted || _particles.isEmpty || !widget.revealed) return;
    final previousTick = _lastTick;
    _lastTick = elapsed;
    if (previousTick == null) return;
    final dt = ((elapsed - previousTick).inMicroseconds / 1000000)
        .clamp(1 / 120, 1 / 30)
        .toDouble();
    _angularVelocity *= math.pow(.045, dt).toDouble();
    _yaw += _angularVelocity * dt;
    _updateTargets();

    for (final particle in _particles.values) {
      if (particle.inverseMass == 0) continue;
      final velocity = (particle.position - particle.previous) * .86;
      particle.previous = particle.position;
      particle.position += velocity;
      particle.anchorLambda = 0;
    }
    for (final constraint in _constraints) {
      constraint.lambda = 0;
    }

    // XPBD: soft target anchors + relationship distance constraints.
    // Compliance keeps the graph elastic instead of snapping to fixed slots.
    for (var iteration = 0; iteration < 7; iteration++) {
      for (final particle in _particles.values) {
        _solveAnchor(particle, dt);
      }
      for (final constraint in _constraints) {
        _solveDistance(constraint, dt);
      }
      _solveSeparation();
      _solveBounds();
    }

    var motion = _angularVelocity.abs();
    for (final particle in _particles.values) {
      motion += (particle.position - particle.previous).distance;
    }
    _calmFrames = motion < .16 ? _calmFrames + 1 : 0;
    if (_calmFrames > 18) {
      _ticker.stop();
      _lastTick = null;
    }
    setState(() {});
  }

  void _solveAnchor(_XpbdParticle particle, double dt) {
    if (particle.inverseMass == 0) {
      particle.position = particle.target;
      return;
    }
    final delta = particle.position - particle.target;
    final length = delta.distance;
    if (length < .0001) return;
    final alpha = .000035 / (dt * dt);
    final correction = (-length - alpha * particle.anchorLambda) /
        (particle.inverseMass + alpha);
    particle.anchorLambda += correction;
    particle.position += delta / length * (correction * particle.inverseMass);
  }

  void _solveDistance(_XpbdDistanceConstraint constraint, double dt) {
    final a = _particles[constraint.a];
    final b = _particles[constraint.b];
    if (a == null || b == null) return;
    final delta = b.position - a.position;
    final length = delta.distance;
    if (length < .0001) return;
    final weights = a.inverseMass + b.inverseMass;
    final alpha = constraint.compliance / (dt * dt);
    final correction =
        (-(length - constraint.restLength) - alpha * constraint.lambda) /
            (weights + alpha);
    constraint.lambda += correction;
    final normal = delta / length;
    a.position -= normal * (correction * a.inverseMass);
    b.position += normal * (correction * b.inverseMass);
  }

  void _solveSeparation() {
    final nodes = _particles.values.toList();
    for (var i = 0; i < nodes.length; i++) {
      for (var j = i + 1; j < nodes.length; j++) {
        final a = nodes[i];
        final b = nodes[j];
        final delta = b.position - a.position;
        final length = delta.distance;
        if (length >= 76 || length < .0001) continue;
        final weights = a.inverseMass + b.inverseMass;
        if (weights == 0) continue;
        final push = (76 - length) / weights;
        final normal = delta / length;
        a.position -= normal * (push * a.inverseMass);
        b.position += normal * (push * b.inverseMass);
      }
    }
  }

  void _solveBounds() {
    for (final particle in _particles.values) {
      if (particle.inverseMass == 0) continue;
      particle.position = Offset(
        particle.position.dx.clamp(38, _middle.dx * 2 - 38).toDouble(),
        particle.position.dy.clamp(42, 268).toDouble(),
      );
    }
  }

  Widget _node(
    StoryPerson person,
    Offset position,
    double scale,
    bool tappable,
  ) {
    final selected = person.personId == _selectedId;
    const nodeWidth = 82.0;
    const nodeHeight = 94.0;
    return Positioned(
      left: position.dx - nodeWidth / 2,
      top: position.dy - nodeHeight / 2,
      width: nodeWidth,
      height: nodeHeight,
      child: Transform.scale(
        scale: scale,
        child: GestureDetector(
          key: ValueKey('relationship-node-${person.personId}'),
          behavior: HitTestBehavior.opaque,
          onTap: tappable ? () => _toggle(person) : null,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                padding: EdgeInsets.all(selected ? 4 : 1.5),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: selected ? storyAccent : Colors.transparent,
                  boxShadow: [
                    BoxShadow(
                      color: storyAccent.withValues(alpha: selected ? .5 : .16),
                      blurRadius: selected ? 24 : 12,
                    ),
                  ],
                ),
                child: widget.avatarBuilder(person, 54),
              ),
              const SizedBox(height: 5),
              Text(
                person.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: selected ? storyAccent : storyInk,
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _XpbdParticle {
  _XpbdParticle(this.position)
      : previous = position,
        target = position,
        inverseMass = 1;

  _XpbdParticle.pinned(this.position)
      : previous = position,
        target = position,
        inverseMass = 0;

  Offset position;
  Offset previous;
  Offset target;
  final double inverseMass;
  double anchorLambda = 0;
}

class _XpbdDistanceConstraint {
  _XpbdDistanceConstraint(
    this.a,
    this.b, {
    required this.restLength,
    required this.compliance,
  });

  final int a;
  final int b;
  final double restLength;
  final double compliance;
  double lambda = 0;
}

class _RelationshipPainter extends CustomPainter {
  const _RelationshipPainter({
    required this.positions,
    required this.links,
    required this.spread,
    required this.center,
    required this.radiusX,
    required this.radiusY,
  });

  final Map<int, Offset> positions;
  final List<StoryLink> links;
  final double spread;
  final Offset center;
  final double radiusX;
  final double radiusY;

  @override
  void paint(Canvas canvas, Size size) {
    final orbitPaint = Paint()
      ..color = Colors.white.withValues(alpha: .075 * spread)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    canvas.drawOval(
      Rect.fromCenter(
        center: center,
        width: radiusX * 2 * spread,
        height: radiusY * 2 * spread,
      ),
      orbitPaint,
    );
    final maxCount = links.fold<int>(1, (n, link) => math.max(n, link.count));
    for (final link in links) {
      final a = positions[link.a];
      final b = positions[link.b];
      if (a == null || b == null) continue;
      final strength = link.count / maxCount;
      final alpha = (.2 + strength * .42) * spread;
      final paint = Paint()
        ..shader = LinearGradient(
          colors: [
            storyAccent.withValues(alpha: alpha),
            const Color(0xFFFFB36B).withValues(alpha: alpha),
          ],
        ).createShader(Rect.fromPoints(a, b))
        ..strokeWidth = .8 + strength * 2;
      canvas.drawLine(a, b, paint);
      canvas.drawCircle(
        Offset.lerp(a, b, .5)!,
        2.2 + strength * 2,
        Paint()..color = storyAccent.withValues(alpha: .55 * spread),
      );
    }
    canvas.drawCircle(
      center,
      62 * spread,
      Paint()
        ..color = storyAccent.withValues(alpha: .055 * spread)
        ..style = PaintingStyle.fill,
    );
  }

  @override
  bool shouldRepaint(covariant _RelationshipPainter oldDelegate) =>
      oldDelegate.positions != positions || oldDelegate.spread != spread;
}
