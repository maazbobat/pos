import 'package:flutter/material.dart';
import 'package:pos_shared/pos_shared.dart';

import 'site_chrome.dart';

/// The privacy policy and terms are drafts until counsel reviews them.
/// While true, each page says so at the top and the [bracketed] blanks stay
/// visible. Turn off only once a lawyer has signed off on the final text.
const legalDraft = true;

/// Last time the wording changed. Update with every edit.
const legalEffectiveDate = '[EFFECTIVE DATE, e.g. 1 December 2026]';

enum LegalPage {
  privacy('Privacy policy', 'privacy'),
  terms('Terms of use', 'terms');

  const LegalPage(this.title, this.path);
  final String title;
  final String path;
}

/// What the policy needs to know about the restaurant. Everything comes from
/// the store's own settings; a missing value shows as a blank to fill in,
/// never an invented one.
class LegalParty {
  const LegalParty({
    required this.name,
    this.address,
    this.phone,
    this.email,
    this.province,
  });

  /// The generic pages at /privacy and /terms, not tied to one restaurant.
  const LegalParty.generic()
    : name = 'the restaurant you order from',
      address = null,
      phone = null,
      email = null,
      province = null;

  factory LegalParty.of(Storefront s) => LegalParty(
    name: s.displayName,
    address: s.address,
    phone: s.phone,
    email: s.email,
    province: s.province,
  );

  final String name;
  final String? address;
  final String? phone;
  final String? email;
  final String? province;

  bool get isGeneric => address == null && phone == null && email == null;

  String get contactLine {
    final parts = [?address, ?phone, ?email];
    return parts.isEmpty
        ? '[RESTAURANT CONTACT: street address, phone and email]'
        : parts.join(' · ');
  }
}

typedef LegalSection = ({String heading, List<String> paragraphs});

/// Draft privacy policy for guests ordering online, written for PIPEDA
/// (and Quebec's Law 25 where it applies). For counsel to review.
List<LegalSection> privacySections(LegalParty p) => [
  (
    heading: 'Who we are',
    paragraphs: [
      'This ordering page belongs to ${p.name}. We use an online ordering '
          'service run by [PLATFORM LEGAL NAME] ("the service provider") to '
          'take your order. We are responsible for your personal information; '
          'the service provider handles it only on our behalf and under '
          'contract with us.',
      'Contact us: ${p.contactLine}.',
      'Our privacy officer is [NAME OR TITLE OF THE RESTAURANT\'S PRIVACY '
          'OFFICER], reachable at the contact details above.',
    ],
  ),
  (
    heading: 'What we collect',
    paragraphs: [
      'When you order: the name to call out, and, if you choose to give them, '
          'your phone number and email address. We also keep what you ordered, '
          'when you want to pick it up, the total and whether it is paid.',
      'If you pay online, your card is handled by our payment processor, '
          'Stripe. We never see or store your full card number.',
      'Like most websites, our servers record technical details such as your '
          'IP address and browser type to keep the service running and secure.',
      'Only if you accept analytics cookies: how you use this page (pages '
          'viewed, items added, orders placed), through Google Analytics. We '
          'don\'t send your name, phone or email to analytics.',
    ],
  ),
  (
    heading: 'Why we use it',
    paragraphs: [
      'To make your order, call it out when it is ready, contact you if '
          'something is wrong with it, send a receipt if you gave an email, '
          'prevent fraud, and keep the records tax law requires.',
      'We don\'t use your details for marketing and we don\'t sell them.',
      'By placing an order you consent to these uses. You can withdraw '
          'consent at any time, subject to legal or contractual limits, but '
          'we may then be unable to take your order.',
    ],
  ),
  (
    heading: 'Who we share it with',
    paragraphs: [
      'Only with service providers who help us take your order: the service '
          'provider (data stored on Google Cloud in Montréal, Canada), Stripe '
          'for card payments, and Google Analytics if you accept analytics '
          'cookies. Stripe and Google may process information outside Canada, '
          'including in the United States, where it may be accessible to '
          'authorities under local law.',
      'We may also disclose information where the law requires it.',
    ],
  ),
  (
    heading: 'How long we keep it',
    paragraphs: [
      'Your phone number and email: [RETENTION PERIOD, e.g. 90 days after '
          'pickup]. Order and payment records: as long as tax law requires '
          '(generally six years in Canada). [COUNSEL TO CONFIRM PERIODS.]',
    ],
  ),
  (
    heading: 'How we protect it',
    paragraphs: [
      'Information is encrypted in transit, stored with a cloud provider that '
          'encrypts it at rest, and only staff who need it to make your order '
          'can see it.',
    ],
  ),
  (
    heading: 'Your choices and rights',
    paragraphs: [
      'You can ask to see the personal information we hold about you, ask us '
          'to correct it, or withdraw your consent. Contact our privacy officer; '
          'we answer within 30 days.',
      'If you\'re not satisfied, you can complain to the Office of the Privacy '
          'Commissioner of Canada (priv.gc.ca) or, where it applies, your '
          'provincial privacy commissioner. [COUNSEL: Quebec Law 25 '
          'requirements if the restaurant is in Quebec.]',
    ],
  ),
  (
    heading: 'Cookies and similar storage',
    paragraphs: [
      'Necessary: this page stores your cookie choice in your browser. Your '
          'cart lives only in the open page and is gone when you close it.',
      'Analytics (optional): only if you choose "Accept", Google Analytics sets '
          'cookies to count visits and see which pages work. Choose "Cookie '
          'settings" at the bottom of any page to change your mind.',
    ],
  ),
  (
    heading: 'Changes',
    paragraphs: [
      'We\'ll post any change here with a new effective date. '
          'Effective: $legalEffectiveDate.',
    ],
  ),
];

/// Draft terms for ordering online. For counsel to review.
List<LegalSection> termsSections(LegalParty p) => [
  (
    heading: 'About these terms',
    paragraphs: [
      'These terms apply when you order from ${p.name} on this page. By '
          'placing an order you agree to them. Contact: ${p.contactLine}.',
    ],
  ),
  (
    heading: 'Orders and prices',
    paragraphs: [
      'Prices and taxes are the restaurant\'s current ones and are confirmed '
          'when you place the order. Items can sell out; if something you '
          'ordered isn\'t available, the restaurant will contact you or adjust '
          'the order.',
      'Pickup times are estimates. Your order is held at the counter for '
          '[HOLD PERIOD, e.g. 30 minutes] after it is ready.',
    ],
  ),
  (
    heading: 'Payment',
    paragraphs: [
      'You can pay at pickup or, where offered, online by card through '
          'Stripe. An online order isn\'t sent to the kitchen until it is paid, '
          'and an unpaid online order is canceled after 30 minutes.',
    ],
  ),
  (
    heading: 'Changes, cancellations and refunds',
    paragraphs: [
      'Contact the restaurant as soon as possible to change or cancel an '
          'order. Once the kitchen has started it, it may not be possible. '
          '[RESTAURANT\'S REFUND POLICY.]',
    ],
  ),
  (
    heading: 'Allergies and dietary needs',
    paragraphs: [
      'Menu descriptions may not list every ingredient. If you have an '
          'allergy, please call the restaurant before ordering. We can\'t '
          'guarantee any item is free of allergens.',
    ],
  ),
  (
    heading: 'Liability',
    paragraphs: [
      '[COUNSEL: limitation of liability, consistent with consumer protection '
          'law in the restaurant\'s province.]',
    ],
  ),
  (
    heading: 'Governing law',
    paragraphs: [
      'These terms are governed by the laws of '
          '${p.province == null ? '[PROVINCE]' : provinceName(p.province!)} and '
          'the federal laws of Canada that apply there. [COUNSEL TO CONFIRM.]',
      'Effective: $legalEffectiveDate.',
    ],
  ),
];

String provinceName(String code) =>
    const {
      'AB': 'Alberta',
      'BC': 'British Columbia',
      'MB': 'Manitoba',
      'NB': 'New Brunswick',
      'NL': 'Newfoundland and Labrador',
      'NS': 'Nova Scotia',
      'NT': 'the Northwest Territories',
      'NU': 'Nunavut',
      'ON': 'Ontario',
      'PE': 'Prince Edward Island',
      'QC': 'Quebec',
      'SK': 'Saskatchewan',
      'YT': 'Yukon',
    }[code] ??
    code;

/// `/privacy`, `/terms`, `/<store>/privacy` and `/<store>/terms`.
class LegalScreen extends StatefulWidget {
  const LegalScreen({super.key, required this.page, this.slug});
  final LegalPage page;

  /// Null for the generic page.
  final String? slug;

  @override
  State<LegalScreen> createState() => _LegalScreenState();
}

class _LegalScreenState extends State<LegalScreen> {
  Future<Storefront>? _store;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (widget.slug != null) {
      _store ??= SiteScope.of(context).backend.storefront(widget.slug!);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_store == null) return _page(context, const LegalParty.generic());
    return FutureBuilder<Storefront>(
      future: _store,
      builder: (context, snap) {
        if (snap.hasError) {
          return isNotFound(snap.error!)
              ? const NotFoundScreen()
              : _page(context, const LegalParty.generic());
        }
        if (!snap.hasData) {
          return SitePage(
            title: widget.page.title,
            noindex: true,
            child: const Scaffold(body: LoadingState('Loading…')),
          );
        }
        return _page(context, LegalParty.of(snap.data!), store: snap.data);
      },
    );
  }

  Widget _page(BuildContext context, LegalParty party, {Storefront? store}) {
    final theme = Theme.of(context);
    final sections = widget.page == LegalPage.privacy
        ? privacySections(party)
        : termsSections(party);
    final title = widget.page.title;
    return SitePage(
      title: store == null ? title : '$title · ${store.displayName}',
      description: widget.page == LegalPage.privacy
          ? 'How ${party.name} handles your personal information when you order online.'
          : 'The terms that apply when you order from ${party.name} online.',
      noindex: store != null,
      path: store == null
          ? '/${widget.page.path}'
          : '/${store.slug}/${widget.page.path}',
      child: Scaffold(
        appBar: AppBar(title: Text(title)),
        body: ResponsiveBody(
          maxWidth: 720,
          children: [
            if (legalDraft)
              Card(
                key: const Key('legal-draft'),
                color: theme.colorScheme.tertiaryContainer,
                child: const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Draft for legal review. Words in [brackets] are still to '
                    'be filled in.',
                  ),
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                store == null ? title : '$title for ${store.displayName}',
                style: theme.textTheme.headlineSmall,
              ),
            ),
            for (final s in sections) ...[
              Padding(
                padding: const EdgeInsets.only(top: 20, bottom: 6),
                child: Semantics(
                  header: true,
                  child: Text(s.heading, style: theme.textTheme.titleMedium),
                ),
              ),
              for (final para in s.paragraphs)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SelectableText(para),
                ),
            ],
            SiteFooter(store: store),
          ],
        ),
      ),
    );
  }
}
