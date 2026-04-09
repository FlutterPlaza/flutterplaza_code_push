import 'package:flutter/material.dart';

import 'code_push.dart';

/// Renders a widget tree from code push module results.
///
/// Place this wherever you want OTA-updatable UI. It listens to
/// [CodePush.moduleResult] and renders the widget IR delivered by
/// the server. When no patch is active, it shows [child].
///
/// ```dart
/// CodePushWidgetArea(
///   child: Text('Default content'),
/// )
/// ```
class CodePushWidgetArea extends StatelessWidget {
  const CodePushWidgetArea({super.key, required this.child});

  /// Default content shown when no patch is active.
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<Object?>(
      valueListenable: CodePush.moduleResult,
      builder: (context, result, _) {
        if (result is Map<String, dynamic>) {
          return _WidgetIR.build(result, context);
        }
        if (result is String && result.isNotEmpty) {
          return Text(result);
        }
        return child;
      },
    );
  }
}

/// Converts widget IR Maps (from the server's WidgetTransformer) into
/// real Flutter widgets.
///
/// The IR uses `_w` to identify widget types and mirrors the constructor
/// parameters defined in the server's widget registry.
class _WidgetIR {
  static Widget build(Map<String, dynamic> desc, [BuildContext? context]) {
    final type = (desc['_w'] ?? desc['type']) as String? ?? '';

    // Navigation support: if _navigate is set, wrap the widget in a
    // tap handler that pushes a new page with the target widget tree.
    final navigate = desc['_navigate'] as Map<String, dynamic>?;
    if (navigate != null && context != null) {
      return _wrapNavigation(desc, navigate, context);
    }

    switch (type) {
      case 'Column':
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisAlignment: _mainAxis(desc['mainAxisAlignment']),
          children: _children(desc, context),
        );
      case 'Row':
        return Row(
          mainAxisAlignment: _mainAxis(desc['mainAxisAlignment']),
          children: _children(desc, context),
        );
      case 'Container':
        return Container(
          padding: _edgeInsets(desc['padding']),
          decoration: desc['color'] != null
              ? BoxDecoration(
                  color: _color(desc['color']),
                  borderRadius: BorderRadius.circular(12),
                )
              : null,
          child: _child(desc, context),
        );
      case 'Card':
        return Card(
          color: _color(desc['color']),
          elevation: (desc['elevation'] as num?)?.toDouble(),
          child: desc['child'] is Map<String, dynamic>
              ? build(desc['child'] as Map<String, dynamic>, context)
              : Padding(
                  padding: _edgeInsets(desc['padding']),
                  child: _child(desc, context),
                ),
        );
      case 'Padding':
        return Padding(
          padding: _edgeInsets(desc['padding']),
          child: _child(desc, context),
        );
      case 'Center':
        return Center(child: _child(desc, context));
      case 'Align':
        return Align(child: _child(desc));
      case 'SizedBox':
        return SizedBox(
          height: (desc['height'] as num?)?.toDouble(),
          width: (desc['width'] as num?)?.toDouble(),
          child: _child(desc, context),
        );
      case 'Expanded':
        return Expanded(
          flex: (desc['flex'] as int?) ?? 1,
          child: _child(desc, context) ?? const SizedBox.shrink(),
        );
      case 'Text':
        final style = desc['style'] as Map<String, dynamic>?;
        return Text(
          (desc['data'] ?? desc['text']) as String? ?? '',
          textAlign: _textAlign(desc['textAlign']),
          maxLines: desc['maxLines'] as int?,
          style: TextStyle(
            fontSize: _double(style?['fontSize'] ?? desc['fontSize']),
            fontWeight:
                (style?['fontWeight'] ?? desc['fontWeight']) == 'bold'
                    ? FontWeight.bold
                    : null,
            color: _color(style?['color'] ?? desc['color']),
          ),
        );
      case 'Icon':
        return Icon(
          _icon((desc['icon'] ?? desc['_positional_0']) as String?),
          size: _double(desc['size']),
          color: _color(desc['color']),
        );
      case 'ElevatedButton':
        return ElevatedButton(
          onPressed: () {},
          child: _child(desc, context),
        );
      case 'TextButton':
        return TextButton(
          onPressed: () {},
          child: _child(desc, context) ?? const SizedBox.shrink(),
        );
      case 'Chip':
        return Chip(label: Text(desc['label'] as String? ?? ''));
      case 'Divider':
        return Divider(
          height: _double(desc['height']),
          thickness: _double(desc['thickness']),
          color: _color(desc['color']),
        );
      case 'Spacer':
        return Spacer(flex: (desc['flex'] as int?) ?? 1);
      case 'Opacity':
        return Opacity(
          opacity: (desc['opacity'] as num?)?.toDouble() ?? 1.0,
          child: _child(desc, context) ?? const SizedBox.shrink(),
        );
      case 'ClipRRect':
        return ClipRRect(child: _child(desc));
      case 'Wrap':
        return Wrap(
          spacing: _double(desc['spacing']) ?? 0,
          runSpacing: _double(desc['runSpacing']) ?? 0,
          children: _children(desc, context),
        );
      case 'ListTile':
        return ListTile(
          title: desc['title'] is Map<String, dynamic>
              ? build(desc['title'] as Map<String, dynamic>, context)
              : null,
          subtitle: desc['subtitle'] is Map<String, dynamic>
              ? build(desc['subtitle'] as Map<String, dynamic>, context)
              : null,
          leading: desc['leading'] is Map<String, dynamic>
              ? build(desc['leading'] as Map<String, dynamic>, context)
              : null,
          trailing: desc['trailing'] is Map<String, dynamic>
              ? build(desc['trailing'] as Map<String, dynamic>, context)
              : null,
        );
      case 'CircularProgressIndicator':
        return const CircularProgressIndicator();
      case 'SingleChildScrollView':
        return SingleChildScrollView(
          padding: _edgeInsets(desc['padding']),
          child: _child(desc, context),
        );
      case 'Scaffold':
        return Scaffold(
          appBar: desc['appBar'] is Map<String, dynamic>
              ? PreferredSize(
                  preferredSize: const Size.fromHeight(56),
                  child: build(desc['appBar'] as Map<String, dynamic>, context),
                )
              : null,
          body: desc['body'] is Map<String, dynamic>
              ? build(desc['body'] as Map<String, dynamic>, context)
              : null,
        );
      case 'AppBar':
        return AppBar(
          title: desc['title'] is Map<String, dynamic>
              ? build(desc['title'] as Map<String, dynamic>, context)
              : desc['title'] is String
                  ? Text(desc['title'] as String)
                  : null,
          backgroundColor: _color(desc['backgroundColor']),
        );
      default:
        return Text('[Unknown widget: $type]',
            style: const TextStyle(color: Colors.red, fontSize: 12));
    }
  }

  // ── Helpers ──────────────────────────────────────────────────────

  static Widget _wrapNavigation(
    Map<String, dynamic> desc,
    Map<String, dynamic> navigate,
    BuildContext context,
  ) {
    // Build the widget without _navigate to avoid infinite recursion.
    final cleanDesc = Map<String, dynamic>.from(desc)..remove('_navigate');
    final child = build(cleanDesc, context);

    return GestureDetector(
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => _NavigatedPage(widgetIR: navigate),
          ),
        );
      },
      child: child,
    );
  }

  static Widget? _child(Map<String, dynamic> desc, [BuildContext? ctx]) {
    final c = desc['child'];
    if (c is Map<String, dynamic>) return build(c, ctx);
    return null;
  }

  static List<Widget> _children(Map<String, dynamic> desc,
      [BuildContext? ctx]) {
    final list = desc['children'] as List<dynamic>?;
    if (list == null) return [];
    return list
        .whereType<Map<String, dynamic>>()
        .map((d) => build(d, ctx))
        .toList();
  }

  static Color? _color(dynamic value) {
    if (value == null) return null;
    if (value is int) return Color(value);
    if (value is String) {
      return Color(int.parse(value.replaceFirst('0x', ''), radix: 16));
    }
    return null;
  }

  static double? _double(dynamic value) {
    if (value is num) return value.toDouble();
    return null;
  }

  static EdgeInsets _edgeInsets(dynamic value) {
    if (value is num) return EdgeInsets.all(value.toDouble());
    if (value is Map<String, dynamic>) {
      final type = value['_type'] as String?;
      if (type == 'EdgeInsets.all') {
        return EdgeInsets.all((value['value'] as num).toDouble());
      }
      if (type == 'EdgeInsets.symmetric') {
        return EdgeInsets.symmetric(
          horizontal: (value['horizontal'] as num?)?.toDouble() ?? 0,
          vertical: (value['vertical'] as num?)?.toDouble() ?? 0,
        );
      }
      // LTRB
      return EdgeInsets.fromLTRB(
        (value['left'] as num?)?.toDouble() ?? 0,
        (value['top'] as num?)?.toDouble() ?? 0,
        (value['right'] as num?)?.toDouble() ?? 0,
        (value['bottom'] as num?)?.toDouble() ?? 0,
      );
    }
    return EdgeInsets.zero;
  }

  static MainAxisAlignment _mainAxis(dynamic value) {
    switch (value) {
      case 'center':
        return MainAxisAlignment.center;
      case 'spaceEvenly':
        return MainAxisAlignment.spaceEvenly;
      case 'spaceBetween':
        return MainAxisAlignment.spaceBetween;
      case 'spaceAround':
        return MainAxisAlignment.spaceAround;
      case 'end':
        return MainAxisAlignment.end;
      default:
        return MainAxisAlignment.start;
    }
  }

  static TextAlign? _textAlign(dynamic value) {
    switch (value) {
      case 'center':
        return TextAlign.center;
      case 'right':
        return TextAlign.right;
      case 'left':
        return TextAlign.left;
      default:
        return null;
    }
  }

  static IconData _icon(String? name) {
    switch (name) {
      case 'check_circle':
        return Icons.check_circle;
      case 'update':
        return Icons.update;
      case 'cloud_done':
        return Icons.cloud_done;
      case 'star':
        return Icons.star;
      case 'home':
        return Icons.home;
      case 'settings':
        return Icons.settings;
      case 'person':
        return Icons.person;
      case 'favorite':
        return Icons.favorite;
      case 'search':
        return Icons.search;
      case 'add':
        return Icons.add;
      case 'delete':
        return Icons.delete;
      case 'edit':
        return Icons.edit;
      case 'arrow_back':
        return Icons.arrow_back;
      case 'arrow_forward':
        return Icons.arrow_forward;
      case 'close':
        return Icons.close;
      case 'menu':
        return Icons.menu;
      case 'info':
        return Icons.info;
      case 'warning':
        return Icons.warning;
      case 'error':
        return Icons.error;
      default:
        return Icons.help_outline;
    }
  }
}

/// A page pushed by the `_navigate` IR action.
class _NavigatedPage extends StatelessWidget {
  const _NavigatedPage({required this.widgetIR});

  final Map<String, dynamic> widgetIR;

  @override
  Widget build(BuildContext context) {
    // If the IR is a Scaffold, render it directly.
    // Otherwise wrap in a Scaffold with a back button.
    final type = (widgetIR['_w'] ?? widgetIR['type']) as String?;
    if (type == 'Scaffold') {
      return _WidgetIR.build(widgetIR, context);
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(
          (widgetIR['_title'] as String?) ?? 'Details',
        ),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: _WidgetIR.build(widgetIR, context),
      ),
    );
  }
}
