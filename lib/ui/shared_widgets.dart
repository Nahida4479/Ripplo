import 'dart:math' as math;
import 'dart:ui' show ImageFilter;

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import 'lucide_icons.dart';
import 'design_tokens.dart';

export 'avatar_widget.dart';
export 'lucide_icons.dart';
export 'design_tokens.dart';

TextStyle rs(BuildContext context, TextStyle base, [Color? color]) =>
    base.copyWith(
      fontFamily: debugFontFamily,
      color: color ?? context.rc.text,
      decoration: TextDecoration.none,
    );

TextStyle monoStyle(BuildContext context, [TextStyle? base, Color? color]) =>
    RipploText.mono(rs(context, base ?? RipploText.body, color));

List<Widget> gapped(List<Widget> kids, double gap, {bool vertical = false}) {
  final out = <Widget>[];
  for (var i = 0; i < kids.length; i++) {
    if (i > 0) {
      out.add(vertical ? SizedBox(height: gap) : SizedBox(width: gap));
    }
    out.add(kids[i]);
  }
  return out;
}

abstract interface class Margined {
  double get marginTop;
  double get marginBottom;
}

double _mt(Widget w) => w is Margined ? (w as Margined).marginTop : 0;
double _mb(Widget w) => w is Margined ? (w as Margined).marginBottom : 0;

List<Widget> vstack(List<Widget> kids, {bool edges = false}) {
  final out = <Widget>[];
  if (kids.isEmpty) return out;
  if (edges && _mt(kids.first) > 0) {
    out.add(SizedBox(height: _mt(kids.first)));
  }
  for (var i = 0; i < kids.length; i++) {
    if (i > 0) {
      final g = math.max(_mb(kids[i - 1]), _mt(kids[i]));
      if (g > 0) out.add(SizedBox(height: g));
    }
    out.add(kids[i]);
  }
  if (edges && _mb(kids.last) > 0) {
    out.add(SizedBox(height: _mb(kids.last)));
  }
  return out;
}

class Pressable extends StatefulWidget {
  const Pressable({
    super.key,
    required this.builder,
    this.onTap,
    this.radius = 0,
    this.label,
    this.toggled,
    this.selected,
  });

  final Widget Function(BuildContext context, bool pressed) builder;
  final VoidCallback? onTap;
  final double radius;
  final String? label;
  final bool? toggled;
  final bool? selected;

  @override
  State<Pressable> createState() => _PressableState();
}

class _PressableState extends State<Pressable> {
  bool _pressed = false;
  bool _focused = false;

  void _setPressed(bool v) {
    if (_pressed != v) setState(() => _pressed = v);
  }

  @override
  Widget build(BuildContext context) {
    final on = widget.onTap != null;
    Widget w = widget.builder(context, _pressed && on);
    if (_focused && on) {
      w = Stack(
        clipBehavior: Clip.none,
        children: [
          w,
          Positioned(
            left: -kFocusOutline * 2,
            top: -kFocusOutline * 2,
            right: -kFocusOutline * 2,
            bottom: -kFocusOutline * 2,
            child: IgnorePointer(
              child: DecoratedBox(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(
                    widget.radius + kFocusOutline * 2,
                  ),
                  border: Border.all(
                    color: context.rc.accent,
                    width: kFocusOutline,
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    }
    return FocusableActionDetector(
      enabled: on,
      onShowFocusHighlight: (v) => setState(() => _focused = v),
      actions: {
        ActivateIntent: CallbackAction<ActivateIntent>(
          onInvoke: (_) {
            widget.onTap?.call();
            return null;
          },
        ),
      },
      child: Semantics(
        button: widget.toggled == null,
        toggled: widget.toggled,
        selected: widget.selected,
        enabled: on,
        label: widget.label,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: on ? (_) => _setPressed(true) : null,
          onTapUp: on ? (_) => _setPressed(false) : null,
          onTapCancel: on ? () => _setPressed(false) : null,
          onTap: widget.onTap,
          child: w,
        ),
      ),
    );
  }
}

class RSpin extends StatefulWidget {
  const RSpin({super.key, required this.child, this.active = true});

  final Widget child;
  final bool active;

  @override
  State<RSpin> createState() => _RSpinState();
}

class _RSpinState extends State<RSpin> with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: kSpinDuration,
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _sync();
  }

  @override
  void didUpdateWidget(RSpin old) {
    super.didUpdateWidget(old);
    _sync();
  }

  void _sync() {
    final run = widget.active && !MediaQuery.disableAnimationsOf(context);
    if (run && !_c.isAnimating) {
      _c.repeat();
    } else if (!run && _c.isAnimating) {
      _c.stop();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      RotationTransition(turns: _c, child: widget.child);
}

class RPage extends StatelessWidget {
  const RPage({
    super.key,
    required this.children,
    this.full = false,
    this.controller,
  });

  final List<Widget> children;
  final bool full;
  final ScrollController? controller;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final pad = MediaQuery.paddingOf(context);
    final top = pad.top + kPageTop;
    final Widget body = full
        ? ClipRect(
            child: Padding(
              padding: EdgeInsets.fromLTRB(kPagePadX, top, kPagePadX, 0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: vstack(children, edges: true),
              ),
            ),
          )
        : SingleChildScrollView(
            controller: controller,
            padding: EdgeInsets.fromLTRB(
              kPagePadX,
              top,
              kPagePadX,
              pad.bottom + kPageBottomReserve,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: vstack(children, edges: true),
            ),
          );
    return DefaultTextStyle(
      style: rs(context, RipploText.body),
      child: Stack(
        fit: StackFit.expand,
        children: [
          ColoredBox(color: c.bg),
          Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: kGlowHeight,
            child: DecoratedBox(
              decoration: BoxDecoration(gradient: c.pageGradient),
            ),
          ),
          body,
        ],
      ),
    );
  }
}

class RBlock extends StatelessWidget implements Margined {
  const RBlock({super.key, required this.children});

  final List<Widget> children;

  @override
  double get marginTop => children.isEmpty ? 0 : _mt(children.first);

  @override
  double get marginBottom => children.isEmpty ? 0 : _mb(children.last);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: vstack(children),
  );
}

class RInline extends StatelessWidget {
  const RInline({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Align(alignment: Alignment.centerLeft, child: child);
}

class RHdr extends StatelessWidget {
  const RHdr({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: kHdrMin),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: gapped(children, 8),
    ),
  );
}

class RHdrTitle extends StatelessWidget {
  const RHdrTitle(this.text, {super.key, this.sub});

  final String text;
  final String? sub;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final h1 = Text(text, style: rs(context, RipploText.h1));
    return Expanded(
      child: sub == null
          ? h1
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                h1,
                Text(sub!, style: rs(context, RipploText.sub, c.text2)),
              ],
            ),
    );
  }
}

class RIconBtn extends StatelessWidget {
  const RIconBtn({
    super.key,
    this.icon,
    this.child,
    this.onTap,
    this.spin = false,
    this.size = kIconSize,
    this.stroke = kIconStroke,
    this.color,
    this.label,
  });

  final LucideData? icon;
  final Widget? child;
  final VoidCallback? onTap;
  final bool spin;
  final double size;
  final double stroke;
  final Color? color;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    Widget inner =
        child ??
        Lucide(icon!, size: size, strokeWidth: stroke, color: color ?? c.text);
    if (spin) inner = RSpin(child: inner);
    return Pressable(
      onTap: onTap,
      label: label,
      radius: kIconBtn / 2,
      builder: (context, pressed) => Container(
        width: kIconBtn,
        height: kIconBtn,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: pressed ? c.surface2 : null,
        ),
        child: inner,
      ),
    );
  }
}

enum RBtnKind { primary, ghost, danger }

class RBtn extends StatelessWidget {
  const RBtn({
    super.key,
    this.text,
    this.child,
    this.icon,
    this.iconSize = 18,
    this.iconStroke = 2,
    this.onTap,
    this.kind = RBtnKind.primary,
    this.sm = false,
    this.block = false,
  });

  final String? text;
  final Widget? child;
  final LucideData? icon;
  final double iconSize;
  final double iconStroke;
  final VoidCallback? onTap;
  final RBtnKind kind;
  final bool sm;
  final bool block;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final (Color bg, Color fg) = switch (kind) {
      RBtnKind.primary => (c.accent, c.onAccent),
      RBtnKind.ghost => (c.surface2, c.text),
      RBtnKind.danger => (const Color(0x00000000), c.danger),
    };
    final style = rs(context, sm ? RipploText.btnSm : RipploText.btn, fg);
    final content = Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: gapped([
        if (icon != null)
          Lucide(icon!, size: iconSize, strokeWidth: iconStroke, color: fg),
        ?child,
        if (text != null)
          Flexible(
            child: Text(text!, style: style, textAlign: TextAlign.center),
          ),
      ], kBtnGap),
    );
    Widget w = Pressable(
      onTap: onTap,
      radius: kRadiusPill,
      builder: (context, pressed) => Container(
        constraints: BoxConstraints(minHeight: sm ? kBtnSmMin : kBtnMin),
        padding: EdgeInsets.symmetric(horizontal: sm ? kBtnSmPadX : kBtnPadX),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(kRadiusPill),
          border: kind == RBtnKind.danger
              ? Border.all(color: c.border, width: kBorderWidth)
              : null,
        ),
        child: DefaultTextStyle(style: style, child: content),
      ),
    );
    if (onTap == null) w = Opacity(opacity: kDisabledOpacity, child: w);
    return block ? SizedBox(width: double.infinity, child: w) : w;
  }
}

enum RChipKind { plain, ok, bad, warn }

class RChip extends StatelessWidget {
  const RChip(
    this.text, {
    super.key,
    this.kind = RChipKind.plain,
    this.icon,
    this.iconSize = 12,
  });

  final String text;
  final RChipKind kind;
  final LucideData? icon;
  final double iconSize;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final fg = switch (kind) {
      RChipKind.plain => c.text2,
      RChipKind.ok => c.ok,
      RChipKind.bad => c.danger,
      RChipKind.warn => c.warn,
    };
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: kChipPadX,
        vertical: kChipPadY,
      ),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: gapped([
          if (icon != null)
            Lucide(icon!, size: iconSize, strokeWidth: 2, color: fg),
          Flexible(child: Text(text, style: rs(context, RipploText.chip, fg))),
        ], kChipGap),
      ),
    );
  }
}

class RDot extends StatelessWidget {
  const RDot({super.key});

  @override
  Widget build(BuildContext context) => Positioned(
    top: kDotTop,
    right: kDotRight,
    child: Container(
      width: kDotSize,
      height: kDotSize,
      decoration: BoxDecoration(
        color: context.rc.danger,
        shape: BoxShape.circle,
      ),
    ),
  );
}

class RBadge extends StatelessWidget {
  const RBadge(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Container(
      constraints: const BoxConstraints(minWidth: kBadgeMin),
      height: kBadgeMin,
      padding: const EdgeInsets.symmetric(horizontal: kBadgePadX),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: c.accent,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Text(
        text,
        style: rs(context, RipploText.badge, c.onAccent),
        maxLines: 1,
      ),
    );
  }
}

class RSection extends StatelessWidget implements Margined {
  const RSection(this.text, {super.key});

  final String text;

  @override
  double get marginTop => 16;

  @override
  double get marginBottom => 8;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 4),
    child: Text(
      text.toUpperCase(),
      style: rs(context, RipploText.section, context.rc.text2),
    ),
  );
}

class _RowScope extends InheritedWidget {
  const _RowScope({required this.first, required super.child});

  final bool first;

  static bool firstOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_RowScope>()?.first ?? true;

  @override
  bool updateShouldNotify(_RowScope old) => first != old.first;
}

class RRows extends StatelessWidget {
  const RRows({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    mainAxisSize: MainAxisSize.min,
    children: [
      for (var i = 0; i < children.length; i++)
        _RowScope(first: i == 0, child: children[i]),
    ],
  );
}

class RCard extends StatelessWidget implements Margined {
  const RCard({
    super.key,
    required this.children,
    this.pad = false,
    this.borderColor,
    this.marginBottom = kCardMarginBottom,
  });

  final List<Widget> children;
  final bool pad;
  final Color? borderColor;

  @override
  final double marginBottom;

  @override
  double get marginTop => 0;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    Widget body = RRows(children: children);
    if (pad) body = Padding(padding: const EdgeInsets.all(kPad), child: body);
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(color: borderColor ?? c.border, width: kBorderWidth),
        borderRadius: BorderRadius.circular(kRadiusCard),
      ),
      child: body,
    );
  }
}

class RRow extends StatelessWidget {
  const RRow({
    super.key,
    required this.children,
    this.onTap,
    this.crossAxis = CrossAxisAlignment.center,
    this.color,
  });

  final List<Widget> children;
  final VoidCallback? onTap;
  final CrossAxisAlignment crossAxis;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final first = _RowScope.firstOf(context);
    final row = Container(
      width: double.infinity,
      constraints: const BoxConstraints(minHeight: kRowMin),
      padding: const EdgeInsets.symmetric(
        horizontal: kRowPadX,
        vertical: kRowPadY,
      ),
      decoration: BoxDecoration(
        border: first
            ? null
            : Border(
                top: BorderSide(color: c.border, width: kBorderWidth),
              ),
      ),
      child: DefaultTextStyle(
        style: rs(context, RipploText.body, color),
        child: Row(
          crossAxisAlignment: crossAxis,
          children: gapped(children, kRowGap),
        ),
      ),
    );
    if (onTap == null) return row;
    return Pressable(onTap: onTap, builder: (_, _) => row);
  }
}

class RLabel extends StatelessWidget {
  const RLabel(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: rs(context, RipploText.rowLabel, color));
}

class RHint extends StatelessWidget {
  const RHint(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: rs(context, RipploText.rowHint, color ?? context.rc.text2),
  );
}

class RVal extends StatelessWidget {
  const RVal(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => Text(
    text,
    style: rs(context, RipploText.rowVal, color ?? context.rc.text2),
  );
}

class RMono extends StatelessWidget {
  const RMono(this.text, {super.key, this.style, this.color});

  final String text;
  final TextStyle? style;
  final Color? color;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: monoStyle(context, style, color ?? style?.color));
}

class RPad extends StatelessWidget {
  const RPad({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) =>
      Padding(padding: const EdgeInsets.all(kPad), child: child);
}

class RSeg<T> extends StatelessWidget {
  const RSeg({
    super.key,
    required this.options,
    required this.value,
    required this.onChanged,
  });

  final List<(T, String)> options;
  final T value;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Container(
      padding: const EdgeInsets.all(kSegPad),
      decoration: BoxDecoration(
        color: c.surface2,
        borderRadius: BorderRadius.circular(kRadiusPill),
      ),
      child: Row(
        children: [
          for (final (v, label) in options)
            Expanded(
              child: Pressable(
                radius: kRadiusPill,
                selected: v == value,
                label: label,
                onTap: () => onChanged(v),
                builder: (context, _) {
                  final on = v == value;
                  return Container(
                    constraints: const BoxConstraints(minHeight: kSegBtnMin),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: on ? c.accent : null,
                      borderRadius: BorderRadius.circular(kRadiusPill),
                    ),
                    child: Text(
                      label,
                      style: rs(
                        context,
                        on ? RipploText.segOn : RipploText.seg,
                        on ? c.onAccent : c.text2,
                      ),
                    ),
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class RSwatches extends StatelessWidget {
  const RSwatches({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 3),
    child: Wrap(
      spacing: kSwatchGap,
      runSpacing: kSwatchGap,
      children: children,
    ),
  );
}

enum RSwatchKind { color, rainbow, none }

class RSwatch extends StatelessWidget {
  const RSwatch({
    super.key,
    this.color,
    this.kind = RSwatchKind.color,
    this.selected = false,
    this.onTap,
    this.label,
  });

  final Color? color;
  final RSwatchKind kind;
  final bool selected;
  final VoidCallback? onTap;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    Widget fill;
    switch (kind) {
      case RSwatchKind.color:
        fill = DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        );
      case RSwatchKind.rainbow:
        fill = const DecoratedBox(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: SweepGradient(
              startAngle: -math.pi / 2,
              endAngle: 3 * math.pi / 2,
              colors: kRainbow,
            ),
          ),
        );
      case RSwatchKind.none:
        fill = ClipOval(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: c.surface2,
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  const Color(0x00000000),
                  const Color(0x00000000),
                  c.danger,
                  c.danger,
                  const Color(0x00000000),
                  const Color(0x00000000),
                ],
                stops: const [0, .46, .46, .54, .54, 1],
              ),
            ),
          ),
        );
    }
    return Pressable(
      onTap: onTap,
      radius: kSwatchSize / 2,
      label: label,
      selected: selected,
      builder: (context, _) => Container(
        width: kSwatchSize,
        height: kSwatchSize,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          boxShadow: selected ? swatchRing(c) : null,
        ),
        child: fill,
      ),
    );
  }
}

class RSwitch extends StatelessWidget {
  const RSwitch({super.key, required this.value, this.onChanged, this.label});

  final bool value;
  final ValueChanged<bool>? onChanged;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Pressable(
      radius: kRadiusPill,
      toggled: value,
      label: label,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      builder: (context, _) => Container(
        width: kSwitchW,
        height: kSwitchH,
        decoration: BoxDecoration(
          color: value ? c.accent : c.surface2,
          borderRadius: BorderRadius.circular(kRadiusPill),
        ),
        child: Stack(
          children: [
            AnimatedPositioned(
              duration: motion(context, kSwitchDuration),
              curve: kSwitchCurve,
              left: kSwitchInset + (value ? kSwitchTravel : 0),
              top: kSwitchInset,
              width: kSwitchKnob,
              height: kSwitchKnob,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? c.onAccent : c.text2,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RField extends StatefulWidget implements Margined {
  const RField({
    super.key,
    this.controller,
    this.focusNode,
    this.hint,
    this.onChanged,
    this.onSubmitted,
    this.enabled = true,
    this.search = false,
    this.obscure = false,
    this.maxLength,
    this.maxLines = 1,
    this.keyboardType,
    this.textInputAction,
    this.autofocus = false,
    this.inputFormatters,
    this.label,
  });

  final TextEditingController? controller;
  final FocusNode? focusNode;
  final String? hint;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final bool enabled;
  final bool search;
  final bool obscure;
  final int? maxLength;
  final int maxLines;
  final TextInputType? keyboardType;
  final TextInputAction? textInputAction;
  final bool autofocus;
  final List<TextInputFormatter>? inputFormatters;
  final String? label;

  @override
  double get marginTop => search ? 4 : 0;

  @override
  double get marginBottom => search ? 12 : 0;

  @override
  State<RField> createState() => _RFieldState();
}

class _RFieldState extends State<RField> {
  FocusNode? _own;
  bool _focused = false;

  FocusNode get _node => widget.focusNode ?? (_own ??= FocusNode());

  @override
  void initState() {
    super.initState();
    _node.addListener(_onFocus);
  }

  @override
  void didUpdateWidget(RField old) {
    super.didUpdateWidget(old);
    if (old.focusNode != widget.focusNode) {
      (old.focusNode ?? _own)?.removeListener(_onFocus);
      _node.addListener(_onFocus);
    }
  }

  void _onFocus() {
    if (_focused != _node.hasFocus) setState(() => _focused = _node.hasFocus);
  }

  @override
  void dispose() {
    _node.removeListener(_onFocus);
    _own?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final style = rs(context, RipploText.body);
    return Container(
      constraints: const BoxConstraints(minHeight: kFieldMin),
      padding: const EdgeInsets.symmetric(horizontal: kFieldPadX),
      alignment: Alignment.centerLeft,
      decoration: BoxDecoration(
        color: c.surface,
        border: Border.all(
          color: _focused ? c.accent : c.border,
          width: kBorderWidth,
        ),
        borderRadius: BorderRadius.circular(
          widget.search ? kRadiusPill : kRadiusField,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: TextField(
          controller: widget.controller,
          focusNode: _node,
          enabled: widget.enabled,
          obscureText: widget.obscure,
          maxLength: widget.maxLength,
          maxLines: widget.maxLines,
          minLines: 1,
          autofocus: widget.autofocus,
          keyboardType: widget.keyboardType,
          textInputAction: widget.textInputAction,
          inputFormatters: widget.inputFormatters,
          onChanged: widget.onChanged,
          onSubmitted: widget.onSubmitted,
          style: style,
          cursorColor: c.text,
          decoration: InputDecoration(
            isCollapsed: true,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            contentPadding: EdgeInsets.zero,
            counterText: '',
            hintText: widget.hint,
            hintStyle: style.copyWith(color: const Color(0xFF757575)),
          ),
        ),
      ),
    );
  }
}

class RListRow extends StatelessWidget {
  const RListRow({super.key, required this.children, this.onTap});

  final List<Widget> children;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return Pressable(
      onTap: onTap,
      radius: kRadiusListRow,
      builder: (context, pressed) => Container(
        width: double.infinity,
        constraints: const BoxConstraints(minHeight: kListRowMin),
        padding: const EdgeInsets.symmetric(
          horizontal: kListRowPadX,
          vertical: kListRowPadY,
        ),
        decoration: BoxDecoration(
          color: pressed ? c.surface : null,
          borderRadius: BorderRadius.circular(kRadiusListRow),
        ),
        child: DefaultTextStyle(
          style: rs(context, RipploText.body),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: gapped(children, kListRowGap),
          ),
        ),
      ),
    );
  }
}

class RListName extends StatelessWidget {
  const RListName(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => Text(
    text,
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    style: rs(context, RipploText.listName),
  );
}

class RListPrev extends StatelessWidget {
  const RListPrev({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
    style: rs(context, RipploText.listPrev, context.rc.text2),
    maxLines: 1,
    softWrap: false,
    overflow: TextOverflow.ellipsis,
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: gapped([
        for (final w in children) w is Text ? Flexible(child: w) : w,
      ], 4),
    ),
  );
}

class RListMeta extends StatelessWidget {
  const RListMeta({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => DefaultTextStyle(
    style: rs(context, RipploText.listMeta, context.rc.text2),
    textAlign: TextAlign.right,
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: gapped(children, 4, vertical: true),
    ),
  );
}

class RTabItem {
  const RTabItem({
    required this.path,
    required this.icon,
    required this.label,
    this.alert = false,
  });

  final String path;
  final LucideData icon;
  final String label;
  final bool alert;
}

class RTabBar extends StatelessWidget {
  const RTabBar({
    super.key,
    required this.items,
    required this.current,
    required this.onSelect,
    this.navLabel,
    this.alertLabel,
  });

  final List<RTabItem> items;
  final String current;
  final ValueChanged<String> onSelect;
  final String? navLabel;
  final String? alertLabel;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final sab = MediaQuery.paddingOf(context).bottom;
    final radius = BorderRadius.circular(kRadiusPill);
    return Positioned(
      left: 0,
      right: 0,
      bottom: sab + kTabBarBottom,
      child: Center(
        heightFactor: 1,
        child: Semantics(
          container: true,
          label: navLabel,
          child: ClipRRect(
            borderRadius: radius,
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: kTabBarBlur,
                sigmaY: kTabBarBlur,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: c.tabBg,
                  borderRadius: radius,
                  border: Border.all(color: c.border, width: kBorderWidth),
                ),
                child: Padding(
                  padding: const EdgeInsets.all(kTabBarPad),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: gapped([
                      for (final it in items) _tab(context, c, it),
                    ], kTabBarGap),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _tab(BuildContext context, RipploColors c, RTabItem it) {
    final on = it.path == current;
    final fg = on ? c.accent : c.text2;
    return Pressable(
      radius: kRadiusPill,
      label: it.label,
      selected: on,
      onTap: () => onSelect(it.path),
      builder: (context, _) => Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(
              horizontal: kTabPadX,
              vertical: kTabPadY,
            ),
            decoration: BoxDecoration(
              color: on ? c.accentSoft : null,
              borderRadius: BorderRadius.circular(kRadiusPill),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: gapped([
                Lucide(
                  it.icon,
                  size: kIconSize,
                  strokeWidth: kIconStroke,
                  color: fg,
                ),
                if (on) Text(it.label, style: rs(context, RipploText.tab, fg)),
              ], kTabGap),
            ),
          ),
          if (it.alert)
            Positioned(
              top: kDotTop,
              right: kDotRight,
              child: Semantics(
                label: alertLabel,
                image: true,
                child: Container(
                  width: kDotSize,
                  height: kDotSize,
                  decoration: BoxDecoration(
                    color: c.danger,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class RSheet extends StatelessWidget {
  const RSheet({
    super.key,
    required this.children,
    required this.onDismiss,
    this.label,
  });

  final List<Widget> children;
  final VoidCallback onDismiss;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final mq = MediaQuery.of(context);
    final kb = mq.viewInsets.bottom;
    final sab = math.max(0.0, mq.padding.bottom - kb);
    return Stack(
      fit: StackFit.expand,
      children: [
        GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onDismiss,
          child: const ColoredBox(color: kScrim),
        ),
        Padding(
          padding: EdgeInsets.only(bottom: kb),
          child: Align(
            alignment: Alignment.bottomCenter,
            child: LayoutBuilder(
              builder: (context, bc) => ConstrainedBox(
                constraints: BoxConstraints(
                  minWidth: math.min(kSheetMaxWidth, bc.maxWidth),
                  maxWidth: math.min(kSheetMaxWidth, bc.maxWidth),
                  maxHeight: bc.maxHeight * kSheetMaxHeightFraction,
                ),
                child: Semantics(
                  container: true,
                  scopesRoute: true,
                  explicitChildNodes: true,
                  namesRoute: label != null,
                  label: label,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {},
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: c.bg,
                        border: Border.all(
                          color: c.border,
                          width: kBorderWidth,
                        ),
                        borderRadius: const BorderRadius.vertical(
                          top: Radius.circular(kRadiusSheet),
                        ),
                      ),
                      child: SingleChildScrollView(
                        padding: EdgeInsets.fromLTRB(
                          kSheetPad + kBorderWidth,
                          kSheetPad + kBorderWidth,
                          kSheetPad + kBorderWidth,
                          sab + kSheetPad + kBorderWidth,
                        ),
                        child: DefaultTextStyle(
                          style: rs(context, RipploText.body),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: vstack(children, edges: true),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class RSheetTitle extends StatelessWidget implements Margined {
  const RSheetTitle(this.text, {super.key});

  final String text;

  @override
  double get marginTop => 4;

  @override
  double get marginBottom => 12;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: rs(context, RipploText.sheetTitle));
}

class RSheetText extends StatelessWidget implements Margined {
  const RSheetText(this.text, {super.key});

  final String text;

  @override
  double get marginTop => 0;

  @override
  double get marginBottom => 16;

  @override
  Widget build(BuildContext context) =>
      Text(text, style: rs(context, RipploText.body, context.rc.text2));
}

class RSheetActions extends StatelessWidget {
  const RSheetActions({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Row(
    children: gapped([for (final w in children) Expanded(child: w)], kBtnGap),
  );
}

class RToast extends StatelessWidget {
  const RToast({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    if (text.isEmpty) return const SizedBox.shrink();
    final c = context.rc;
    final mq = MediaQuery.of(context);
    return Positioned(
      left: 0,
      right: 0,
      bottom: mq.padding.bottom + kToastBottom,
      child: Center(
        heightFactor: 1,
        child: Semantics(
          liveRegion: true,
          container: true,
          child: Container(
            constraints: BoxConstraints(
              maxWidth: math.min(
                mq.size.width * kToastMaxWidthFraction,
                kToastMaxWidth,
              ),
            ),
            padding: const EdgeInsets.symmetric(
              horizontal: kToastPadX,
              vertical: kToastPadY,
            ),
            decoration: BoxDecoration(
              color: c.surface2,
              border: Border.all(color: c.border, width: kBorderWidth),
              borderRadius: BorderRadius.circular(kRadiusToast),
              boxShadow: kToastShadow,
            ),
            child: Text(
              text,
              textAlign: TextAlign.center,
              style: rs(context, RipploText.toast),
            ),
          ),
        ),
      ),
    );
  }
}

class RCenter extends StatelessWidget {
  const RCenter({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => ColoredBox(
    color: context.rc.bg,
    child: SizedBox.expand(
      child: DefaultTextStyle(
        style: rs(context, RipploText.body),
        textAlign: TextAlign.center,
        child: Padding(
          padding: const EdgeInsets.all(kCenterPad),
          child: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: gapped(children, kCenterGap, vertical: true),
            ),
          ),
        ),
      ),
    ),
  );
}

class RCenterText extends StatelessWidget {
  const RCenterText(this.text, {super.key, this.color});

  final String text;
  final Color? color;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: kCenterTextMaxWidth),
    child: Text(
      text,
      textAlign: TextAlign.center,
      style: rs(context, RipploText.body, color ?? context.rc.text2),
    ),
  );
}

class REmpty extends StatelessWidget {
  const REmpty(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) => SizedBox(
    width: double.infinity,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        vertical: kEmptyPadY,
        horizontal: kEmptyPadX,
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: rs(context, RipploText.body, context.rc.text2),
      ),
    ),
  );
}

class RDevWarnRow extends StatelessWidget {
  const RDevWarnRow(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    return RRow(
      color: c.danger,
      children: [
        Lucide(LucideIcons.triangleAlert, size: kIconSize, color: c.danger),
        Expanded(
          child: Text(
            text,
            style: rs(
              context,
              RipploText.body.copyWith(fontWeight: FontWeight.w600),
              c.danger,
            ),
          ),
        ),
      ],
    );
  }
}

class RTypingDots extends StatefulWidget {
  const RTypingDots({super.key, this.freeze});

  final Duration? freeze;

  @override
  State<RTypingDots> createState() => _RTypingDotsState();
}

class _RTypingDotsState extends State<RTypingDots>
    with SingleTickerProviderStateMixin {
  static const double _period = 1.2;
  static const List<double> _delays = [0, .15, .3];

  late final Ticker _ticker = createTicker((d) {
    setState(() => _t = d.inMicroseconds / 1e6);
  });
  double _t = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final run =
        widget.freeze == null && !MediaQuery.disableAnimationsOf(context);
    if (run && !_ticker.isActive) {
      _ticker.start();
    } else if (!run && _ticker.isActive) {
      _ticker.stop();
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    super.dispose();
  }

  (double, double) _frame(double t, double delay) {
    if (t < delay) return (1, 0);
    final p = (((t - delay) % _period) / _period);
    double lerp(double a, double b, double x) =>
        a + (b - a) * Curves.easeInOut.transform(x.clamp(0, 1));
    if (p < .3) return (lerp(.3, 1, p / .3), lerp(0, -4, p / .3));
    if (p < .6) return (lerp(1, .3, (p - .3) / .3), lerp(-4, 0, (p - .3) / .3));
    return (.3, 0);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.rc;
    final still = MediaQuery.disableAnimationsOf(context);
    final t = widget.freeze != null ? widget.freeze!.inMicroseconds / 1e6 : _t;
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: gapped([
        for (final d in _delays)
          Builder(
            builder: (context) {
              final (o, y) = still && widget.freeze == null
                  ? (.6, 0.0)
                  : _frame(t, d);
              return Transform.translate(
                offset: Offset(0, y),
                child: Opacity(
                  opacity: o,
                  child: Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: c.text2,
                      shape: BoxShape.circle,
                    ),
                  ),
                ),
              );
            },
          ),
      ], 4),
    );
  }
}
