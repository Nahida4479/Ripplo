import 'package:material_ui/material_ui.dart';

import '../widgets.dart';

class FracText extends StatelessWidget {
  const FracText(
    this.text,
    this.style, {
    super.key,
    this.dy = 0,
    this.extra = 0,
  });

  final String text;
  final TextStyle style;
  final double dy;
  final double extra;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, c) {
      final tp = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
      )..layout(maxWidth: c.maxWidth);
      final lines = tp.computeLineMetrics().length;
      final lh = style.fontSize! * style.height!;
      return SizedBox(
        height: lines * lh + extra,
        child: OverflowBox(
          alignment: Alignment.topLeft,
          maxHeight: double.infinity,
          child: Transform.translate(
            offset: Offset(0, dy),
            child: Text(text, style: style),
          ),
        ),
      );
    },
  );
}

class SectionHead extends StatelessWidget implements Margined {
  const SectionHead(this.text, {super.key});

  final String text;

  @override
  double get marginTop => 16;

  @override
  double get marginBottom => 8;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: FracText(
      text.toUpperCase(),
      rs(context, RipploText.section, context.rc.text2),
      dy: -2,
    ),
  );
}
