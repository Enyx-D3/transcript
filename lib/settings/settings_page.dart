// lib/settings/settings_page.dart
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import 'package:transcript/ui/glass/glass_button.dart';
import 'package:url_launcher/url_launcher.dart';

import 'package:transcript/widgets/icon_pill_button.dart';

import '../common/app_flushbar.dart';
import '../import_export/transcript_porter.dart';
import '../trash/trash_page.dart';
import '../tabs/account_tab.dart';
import '../model_picker_page.dart';

// in-app review prompt
import '../rate/rate_prompt_dialog.dart';

// pages
import '../whats_new/whats_new_page.dart';
import '../hippa/hipaa_friendly_page.dart';
import '../help/help_page.dart';

// ✅ glass system
import '../ui/glass/glass_card.dart';
import '../ui/glass/glass_divider.dart';
import '../ui/glass/glass_tokens.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({
    super.key,
    this.onUpgradeSuccess,
    this.openAccount = false,
  });

  final VoidCallback? onUpgradeSuccess;
  final bool openAccount;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  bool _loading = true;

  bool _busyExport = false;
  bool _busyImport = false;

  // =========================
  // SharedPreferences keys
  // =========================
  static const _kPrefDefaultLang = 'pref_default_lang';
  static const _kPrefTranslateToEnglish = 'pref_translate_to_english';
  static const _kPrefDiarizationEnabled = 'pref_diarization_enabled';
  static const _kPrefDeleteAudioAfter = 'pref_delete_audio_after_transcription';
  static const _kPrefMaxRecordingMinutes = 'pref_max_recording_minutes';
  static const _kPrefAutoEmailTranscript = 'pref_auto_email_transcript';
  static const _kPrefAutoSummaryEnabled = 'pref_auto_summary_enabled';

  // ✅ NEW: typo fix toggle
  static const _kPrefTypoFixEnabled = 'pref_typo_fix_enabled';

  // =========================
  // Support constants
  // =========================
  static const String _supportEmail = 'contact@enyx.app';
  static const String _androidStoreUrl =
      'https://play.google.com/store/apps/details?id=com.enyxd.transcript';

  // =========================
  // Options
  // =========================
  static const Map<String, String> _langOptions = {
    'en': 'English',
    'es': 'Spanish',
    'fr': 'French',
    'ar': 'Arabic',
    'pt': 'Portuguese',
    'it': 'Italian',
    'zh': 'Chinese',
    'auto': 'Auto',
  };

  // static const List<int> _maxMinutesOptions = [30, 60, 90, 120, 6000];
  static const List<int> _maxMinutesOptions = [30, 60];

  // =========================
  // State defaults
  // =========================
  String _defaultLang = 'en';
  bool _translateToEnglish = false;
  bool _diarizationEnabled = true;
  bool _deleteAudioAfterTranscription = false;
  int _maxRecordingMinutes = 60;
  bool _autoEmailTranscript = false;
  bool _autoSummaryEnabled = true; // ✅ default ON

  // ✅ NEW: default ON
  bool _typoFixEnabled = true;

  @override
  void initState() {
    super.initState();
    _load();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.openAccount) _openAccount();
    });
  }

  // =========================
  // Account
  // =========================
  void _openAccount() {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => Scaffold(
          backgroundColor: Colors.transparent,
          appBar: AppBar(
            backgroundColor: Colors.transparent,
            elevation: 0,
            title: const Text('Account'),
            leading: Padding(
              padding: const EdgeInsets.all(7.0),
              child: IconPillButton(
                tooltip: 'Back',
                icon: Icons.arrow_back,
                onTap: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          body: AccountTab(onUpgradeSuccess: widget.onUpgradeSuccess),
        ),
      ),
    );
  }

  // =========================
  // Support actions
  // =========================
  Future<void> _openWhatsNew() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const WhatsNewPage()),
    );
  }

  Future<void> _openModelPage() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const ModelPickerPage()),
    );
  }

  Future<void> _openHipaaFriendly() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HipaaFriendlyPage()),
    );
  }

  Future<void> _openHelp() async {
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const HelpPage()),
    );
  }

  Future<void> _contactSupport() async {
    if (!mounted) return;

    await AppFlushbar.info(context, message: 'Email: $_supportEmail');

    final uri = Uri(
      scheme: 'mailto',
      path: _supportEmail,
      queryParameters: {'subject': 'Transcript Support'},
    );

    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  Future<void> _rateApp() async {
    if (!mounted) return;
    await showRatePrompt(context);
  }

  Future<void> _shareApp() async {
    await SharePlus.instance.share(
      ShareParams(
        text: 'Try Meeting Transcript Unlimited:\n$_androidStoreUrl',
        subject: 'Unlimited Meeting Transcription app',
      ),
    );
  }

  // =========================
  // Load
  // =========================
  Future<void> _load() async {
    final sp = await SharedPreferences.getInstance();

    final lang = sp.getString(_kPrefDefaultLang) ?? 'en';
    final translate = sp.getBool(_kPrefTranslateToEnglish) ?? false;
    final diar = sp.getBool(_kPrefDiarizationEnabled) ?? true;
    final del = sp.getBool(_kPrefDeleteAudioAfter) ?? false;

    final mins = sp.getInt(_kPrefMaxRecordingMinutes) ?? 60;
    final safeMins = _maxMinutesOptions.contains(mins) ? mins : 60;

    final autoEmail = sp.getBool(_kPrefAutoEmailTranscript) ?? false;
    final autoSummary = sp.getBool(_kPrefAutoSummaryEnabled) ?? true;

    // ✅ NEW (default ON)
    final typoFix = sp.getBool(_kPrefTypoFixEnabled) ?? false;

    if (!mounted) return;
    setState(() {
      _defaultLang = _langOptions.containsKey(lang) ? lang : 'en';
      _translateToEnglish = translate;
      _diarizationEnabled = diar;
      _deleteAudioAfterTranscription = del;
      _maxRecordingMinutes = safeMins;
      _autoEmailTranscript = autoEmail;
      _autoSummaryEnabled = autoSummary;

      _typoFixEnabled = typoFix;

      _loading = false;
    });
  }

  // =========================
  // Setters
  // =========================
  Future<void> _setDefaultLang(String v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setString(_kPrefDefaultLang, v);
    if (!mounted) return;
    setState(() => _defaultLang = v);
  }

  Future<void> _setTranslateToEnglish(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPrefTranslateToEnglish, v);
    if (!mounted) return;
    setState(() => _translateToEnglish = v);
  }

  Future<void> _setDiarizationEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPrefDiarizationEnabled, v);
    if (!mounted) return;
    setState(() => _diarizationEnabled = v);
  }

  Future<void> _setDeleteAudioAfter(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPrefDeleteAudioAfter, v);
    if (!mounted) return;
    setState(() => _deleteAudioAfterTranscription = v);
  }

  Future<void> _setMaxRecordingMinutes(int v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setInt(_kPrefMaxRecordingMinutes, v);
    if (!mounted) return;
    setState(() => _maxRecordingMinutes = v);
  }

  Future<void> _setAutoEmailTranscript(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPrefAutoEmailTranscript, v);
    if (!mounted) return;
    setState(() => _autoEmailTranscript = v);
  }

  Future<void> _setAutoSummaryEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPrefAutoSummaryEnabled, v);
    if (!mounted) return;
    setState(() => _autoSummaryEnabled = v);
  }

  // ✅ NEW setter
  Future<void> _setTypoFixEnabled(bool v) async {
    final sp = await SharedPreferences.getInstance();
    await sp.setBool(_kPrefTypoFixEnabled, v);
    if (!mounted) return;
    setState(() => _typoFixEnabled = v);
  }

  // =========================
  // ZIP Export/Import
  // =========================
  Future<void> _exportZip() async {
    if (_busyExport || _busyImport) return;
    setState(() => _busyExport = true);

    try {
      await TranscriptPorter.exportZipAndShare(includeAudio: true);
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Export failed: $e');
    } finally {
      if (mounted) setState(() => _busyExport = false);
    }
  }

  Future<void> _importZip() async {
    if (_busyExport || _busyImport) return;

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color.fromARGB(190, 0, 0, 0),
        surfaceTintColor: Colors.transparent,
        title: const Text('Import transcripts + audio?'),
        content: const Text(
          'This will add transcripts (and their audio if included) from a ZIP export into your database.\n\n'
          '*Duplicates are not automatically removed.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          GlassButton(
            label: 'Import',
            onPressed: () => Navigator.pop(ctx, true),
            expand: false,
            kind: GlassButtonKind.secondary,
          ),
        ],
      ),
    );

    if (ok != true) return;

    setState(() => _busyImport = true);

    try {
      final n = await TranscriptPorter.pickAndImportZip();
      if (!mounted) return;

      if (n == 0) {
        await AppFlushbar.success(context, message: 'No file selected.');
      } else {
        await AppFlushbar.success(context, message: 'Imported $n transcripts.');
      }
    } catch (e) {
      if (!mounted) return;
      await AppFlushbar.error(context, message: 'Import failed: $e');
    } finally {
      if (mounted) setState(() => _busyImport = false);
    }
  }

  Widget _busyTrailing(bool busy) {
    return busy
        ? const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: Colors.white,
              backgroundColor: Colors.black,
            ),
          )
        : Icon(
            Icons.chevron_right,
            color: Colors.white.withValues(alpha: 0.70),
          );
  }

  // =========================
  // UI helpers (glass style)
  // =========================

  Widget _sectionHeader(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 14, 4, 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w900,
          color: Colors.white.withValues(alpha: 0.70),
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _rowDivider() => const GlassDivider(height: 1, thickness: 0.8);

  Widget _panel({required Widget child}) {
    return GlassCard(
      variant: GlassCardVariant.tile,
      padding: const EdgeInsets.all(16),
      child: child,
    );
  }

  Widget _trailingDropdown<T>({
    required T value,
    required List<DropdownMenuItem<T>> items,
    required ValueChanged<T?> onChanged,
    double width = 160,
  }) {
    return SizedBox(
      width: width,
      child: GlassCard(
        variant: GlassCardVariant.tile,
        borderRadius: BorderRadius.circular(14),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        shadow: false,
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: value,
            isExpanded: true,
            items: items,
            onChanged: onChanged,
            dropdownColor: const Color.fromARGB(170, 0, 0, 0),
            iconEnabledColor: Colors.white.withValues(alpha: 0.80),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.92),
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ),
    );
  }

  Widget _kvRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget trailing,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          Icon(icon, color: Colors.white.withValues(alpha: 0.85)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontWeight: FontWeight.w900,
                    color: Colors.white.withValues(alpha: 0.92),
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  subtitle,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.70),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 10),
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 0),
            child: trailing,
          ),
        ],
      ),
    );
  }

  Widget _switchRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
    required String onLabel,
    required String offLabel,
  }) {
    final label = value ? onLabel : offLabel;

    return InkWell(
      onTap: () => onChanged(!value),
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: Colors.white.withValues(alpha: 0.85)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.white.withValues(alpha: 0.92),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.70),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.70),
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(width: 10),
            Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: Colors.black,
              activeTrackColor: Colors.white.withValues(alpha: 0.85),
              inactiveThumbColor: Colors.white.withValues(alpha: 0.55),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.18),
            ),
          ],
        ),
      ),
    );
  }

  String _fmtMaxTime(int minutes) {
    if (minutes == 30) return '30 min';
    if (minutes == 60) return '1 hour';
    // if (minutes == 90) return '1.5 hours';
    // if (minutes == 120) return '2 hours';
    // if (minutes == 6000) return 'No limit (Experimental)';
    return '$minutes min';
  }

  // =========================
  // Build
  // =========================
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.transparent,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Settings'),
        leading: Padding(
          padding: const EdgeInsets.all(7.0),
          child: IconPillButton(
            tooltip: 'Back',
            icon: Icons.arrow_back,
            onTap: () => Navigator.of(context).pop(),
          ),
        ),
      ),
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(
                backgroundColor: Colors.black,
                color: Colors.white,
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 14, 12, 28),
              children: [
                const SizedBox(height: 8),

                _panel(
                  child: InkWell(
                    onTap: _openAccount,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.person_outline,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Account & Billing',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white.withValues(alpha: 0.92),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'Subscription, trial, and purchases',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.70),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: Colors.white.withValues(alpha: 0.70),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                _panel(
                  child: InkWell(
                    onTap: _openModelPage,
                    borderRadius: BorderRadius.circular(14),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Row(
                        children: [
                          Icon(
                            Icons.smart_toy,
                            color: Colors.white.withValues(alpha: 0.85),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Models',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w900,
                                    color: Colors.white.withValues(alpha: 0.92),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  'Model for AI features',
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.70),
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Icon(
                            Icons.chevron_right,
                            color: Colors.white.withValues(alpha: 0.70),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // -------- Recording --------
                _sectionHeader('Recording'),
                _panel(
                  child: Column(
                    children: [
                      _kvRow(
                        icon: Icons.timer_outlined,
                        title: 'Max recording time',
                        subtitle: 'Stops recording automatically at the selected limit.',
                        trailing: _trailingDropdown<int>(
                          value: _maxRecordingMinutes,
                          width: 170,
                          items: _maxMinutesOptions
                              .map(
                                (m) => DropdownMenuItem<int>(
                                  value: m,
                                  child: Text(
                                    _fmtMaxTime(m),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            _setMaxRecordingMinutes(v);
                          },
                        ),
                      ),
                      _rowDivider(),
                      _kvRow(
                        icon: Icons.language_outlined,
                        title: 'Default language',
                        subtitle: 'Preselects language in Record.',
                        trailing: _trailingDropdown<String>(
                          value: _defaultLang,
                          width: 170,
                          items: _langOptions.entries
                              .map(
                                (e) => DropdownMenuItem<String>(
                                  value: e.key,
                                  child: Text(
                                    e.value,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v == null) return;
                            _setDefaultLang(v);
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                // -------- Transcription --------
                _sectionHeader('Transcription'),
                _panel(
                  child: Column(
                    children: [
                      _switchRow(
                        icon: Icons.translate_outlined,
                        title: 'Translate to English',
                        subtitle: 'Applies to background transcription.',
                        value: _translateToEnglish,
                        onChanged: _setTranslateToEnglish,
                        onLabel: 'On',
                        offLabel: 'Off',
                      ),
                      _rowDivider(),
                      _switchRow(
                        icon: Icons.record_voice_over_outlined,
                        title: 'Speaker diarization',
                        subtitle: 'Identifies speakers in the transcript.',
                        value: _diarizationEnabled,
                        onChanged: _setDiarizationEnabled,
                        onLabel: 'On',
                        offLabel: 'Off',
                      ),
                      _rowDivider(),

                      // ✅ NEW: typo fix switch (default ON)
                      _switchRow(
                        icon: Icons.spellcheck,
                        title: 'Fix obvious typos',
                        subtitle:
                            'Runs a lightweight AI pass to correct only obvious typos.',
                        value: _typoFixEnabled,
                        onChanged: _setTypoFixEnabled,
                        onLabel: 'On',
                        offLabel: 'Off',
                      ),

                      _rowDivider(),
                      _switchRow(
                        icon: Icons.auto_awesome,
                        title: 'Auto-generate summary',
                        subtitle: 'Starts summary automatically when transcription finishes.',
                        value: _autoSummaryEnabled,
                        onChanged: _setAutoSummaryEnabled,
                        onLabel: 'On',
                        offLabel: 'Off',
                      ),
                      _rowDivider(),
                      _switchRow(
                        icon: Icons.delete_outline,
                        title: 'Delete audio after transcription',
                        subtitle: 'Frees storage after processing finishes.',
                        value: _deleteAudioAfterTranscription,
                        onChanged: _setDeleteAudioAfter,
                        onLabel: 'On',
                        offLabel: 'Off',
                      ),
                      _rowDivider(),
                      _switchRow(
                        icon: Icons.email_outlined,
                        title: 'Auto email transcript (.txt)',
                        subtitle:
                            'Sends the transcript to your account email when processing finishes.',
                        value: _autoEmailTranscript,
                        onChanged: _setAutoEmailTranscript,
                        onLabel: 'On',
                        offLabel: 'Off',
                      ),
                    ],
                  ),
                ),

                // -------- Import / Export --------
                _sectionHeader('Data & Backup'),
                _panel(
                  child: Column(
                    children: [
                      InkWell(
                        onTap: (!_busyExport && !_busyImport) ? _exportZip : null,
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            children: [
                              Icon(
                                Icons.archive_outlined,
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Export transcripts + audio (ZIP)',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: Colors.white.withValues(alpha: 0.92),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      'Share to Drive / device / email',
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.70),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _busyTrailing(_busyExport),
                            ],
                          ),
                        ),
                      ),
                      _rowDivider(),
                      InkWell(
                        onTap: (!_busyExport && !_busyImport) ? _importZip : null,
                        borderRadius: BorderRadius.circular(14),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Row(
                            children: [
                              Icon(
                                Icons.unarchive_outlined,
                                color: Colors.white.withValues(alpha: 0.85),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Import transcripts + audio (ZIP)',
                                      style: TextStyle(
                                        fontWeight: FontWeight.w900,
                                        color: Colors.white.withValues(alpha: 0.92),
                                      ),
                                    ),
                                    const SizedBox(height: 3),
                                    Text(
                                      'Pick ZIP from device / Drive',
                                      style: TextStyle(
                                        color: Colors.white.withValues(alpha: 0.70),
                                        fontSize: 12,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              _busyTrailing(_busyImport),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // -------- Help & Feedback --------
                _sectionHeader('Help & Feedback'),
                _panel(
                  child: Column(
                    children: [
                      _navRow(
                        icon: Icons.privacy_tip_outlined,
                        title: 'HIPAA-friendly architecture',
                        subtitle: 'Privacy-first design and risk reduction',
                        onTap: _openHipaaFriendly,
                      ),
                      _rowDivider(),
                      _navRow(
                        icon: Icons.delete_outline,
                        title: 'Trash',
                        subtitle: 'Deleted transcripts are kept for 3 days',
                        onTap: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => const TrashPage()),
                        ),
                      ),
                      _rowDivider(),
                      _navRow(
                        icon: Icons.new_releases_outlined,
                        title: 'What’s new',
                        subtitle: 'Recent updates and improvements',
                        onTap: _openWhatsNew,
                      ),
                      _rowDivider(),
                      _navRow(
                        icon: Icons.support_agent_outlined,
                        title: 'Contact support',
                        subtitle: _supportEmail,
                        onTap: _contactSupport,
                      ),
                      _rowDivider(),
                      _navRow(
                        icon: Icons.star_rate_rounded,
                        title: 'Rate the app',
                        subtitle: 'A quick review helps a lot',
                        onTap: _rateApp,
                      ),
                      _rowDivider(),
                      _navRow(
                        icon: Icons.ios_share_outlined,
                        title: 'Share the app',
                        subtitle: 'Send the Play Store link',
                        onTap: _shareApp,
                      ),
                      _rowDivider(),
                      _navRow(
                        icon: Icons.help_outline,
                        title: 'Help',
                        subtitle: 'FAQs and contact',
                        onTap: _openHelp,
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _navRow({
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: Colors.white.withValues(alpha: 0.85)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontWeight: FontWeight.w900,
                      color: Colors.white.withValues(alpha: 0.92),
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    subtitle,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.70),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: Colors.white.withValues(alpha: 0.70),
            ),
          ],
        ),
      ),
    );
  }
}