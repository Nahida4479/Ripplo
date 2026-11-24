import 'dart:typed_data';

import 'package:material_ui/material_ui.dart';

import '../util/avatar.dart';
import '../util/bytes.dart';
import 'icons.dart';
import 'tokens.dart';

export '../util/avatar.dart' show isAvatar, maxAvatar;

class Avatar extends StatefulWidget {
  const Avatar({
    super.key,
    this.name,
    this.size = 48,
    this.group = false,
    this.shield = false,
    this.photo,
  });

  final String? name;
  final double size;
  final bool group;
  final bool shield;
  final String? photo;

  @override
  State<Avatar> createState() => _AvatarState();
}

class _AvatarState extends State<Avatar> {
  Uint8List? _bytes;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(Avatar old) {
    super.didUpdateWidget(old);
    if (old.photo != widget.photo) _decode();
  }

  void _decode() {
    final p = widget.photo;
    if (p == null || p.isEmpty) {
      _bytes = null;
      return;
    }
    try {
      _bytes = unb64(p);
    } catch (_) {
      _bytes = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final size = widget.size;
    final bg = HSLColor.fromAHSL(
      1,
      avatarHue(widget.name).toDouble(),
      .45,
      .38,
    ).toColor();
    const white = Color(0xFFFFFFFF);
    final Widget inner;
    if (_bytes != null && !widget.group) {
      inner = ClipOval(
        child: Image.memory(
          _bytes!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          errorBuilder: (_, _, _) => const SizedBox.shrink(),
        ),
      );
    } else if (widget.group) {
      inner = Lucide(
        LucideIcons.users,
        size: size * .5,
        strokeWidth: 1.75,
        color: white,
      );
    } else {
      inner = Text(
        avatarInitials(widget.name),
        style: TextStyle(
          fontSize: size * .38,
          height: 1.4,
          fontWeight: FontWeight.w600,
          color: white,
          decoration: TextDecoration.none,
          leadingDistribution: TextLeadingDistribution.even,
        ),
      );
    }
    return ExcludeSemantics(
      child: SizedBox(
        width: size,
        height: size,
        child: Stack(
          clipBehavior: Clip.none,
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child: DecoratedBox(
                decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
              ),
            ),
            Center(child: inner),
            if (widget.shield)
              Positioned(
                right: -3,
                bottom: -3,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: c.bg,
                    shape: BoxShape.circle,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(2),
                    child: Lucide(
                      LucideIcons.shieldAlert,
                      size: size * .34,
                      strokeWidth: 2.25,
                      color: c.warn,
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
