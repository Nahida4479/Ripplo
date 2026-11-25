import 'package:flutter_svg/flutter_svg.dart';
import 'package:material_ui/material_ui.dart';

import '../widgets.dart';

const _iconSvg =
    '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#5b8cff"/><stop offset="1" stop-color="#14b8a6"/></linearGradient></defs><rect width="1024" height="1024" rx="224" fill="url(#g)"/><path d="M512 232c-170 0-300 112-300 262 0 78 36 148 96 196l-26 110 128-62c32 9 66 14 102 14 170 0 300-112 300-258S682 232 512 232z" fill="#fff"/><circle cx="512" cy="494" r="42" fill="url(#g)"/><circle cx="512" cy="494" r="108" fill="none" stroke="url(#g)" stroke-width="36" opacity=".85"/><circle cx="512" cy="494" r="178" fill="none" stroke="url(#g)" stroke-width="36" opacity=".55"/></svg>';

class AppIcon extends StatelessWidget {
  const AppIcon({super.key, this.size = 88});

  final double size;

  @override
  Widget build(BuildContext context) =>
      SvgPicture.string(_iconSvg, width: size, height: size);
}

class ScrollCenter extends StatelessWidget {
  const ScrollCenter({super.key, required this.children, this.background});

  final List<Widget> children;
  final Color? background;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: background ?? context.rc.bg,
    child: LayoutBuilder(
      builder: (context, bc) => SingleChildScrollView(
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: bc.maxHeight),
          child: DefaultTextStyle(
            style: rs(context, RipploText.body),
            textAlign: TextAlign.center,
            child: Padding(
              padding: const EdgeInsets.all(kCenterPad),
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: gapped(children, kCenterGap, vertical: true),
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class Narrow extends StatelessWidget {
  const Narrow({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 420),
    child: SizedBox(width: double.infinity, child: child),
  );
}

class Nudge extends StatelessWidget {
  const Nudge(this.dy, {super.key, required this.child});

  final double dy;
  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Transform.translate(offset: Offset(0, dy), child: child);
}

TextStyle brandH1(BuildContext context) =>
    rs(context, RipploText.h1.copyWith(fontSize: 30));
