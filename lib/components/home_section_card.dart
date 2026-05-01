part of 'components.dart';

class HomeSectionCard extends StatelessWidget {
  const HomeSectionCard({
    super.key,
    required this.title,
    this.count,
    required this.onTap,
    this.content,
    this.actions,
    this.trailing,
  });

  final String title;
  final int? count;
  final VoidCallback onTap;
  final Widget? content;
  final Widget? actions;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(AppSpace.sm),
      decoration: BoxDecoration(
        border: Border.all(color: context.colorScheme.outlineVariant),
        borderRadius: BorderRadius.circular(AppRadius.md),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadius.md),
        onTap: onTap,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildTitleRow(context),
            if (content != null) content!,
            if (actions != null) actions!,
          ],
        ),
      ),
    );
  }

  Widget _buildTitleRow(BuildContext context) {
    return SizedBox(
      height: 56,
      child: Row(
        children: [
          Center(child: Text(title, style: ts.s18)),
          if (count != null)
            Container(
              margin: const EdgeInsets.symmetric(horizontal: AppSpace.sm),
              padding: const EdgeInsets.symmetric(
                horizontal: AppSpace.sm,
                vertical: 2,
              ),
              decoration: BoxDecoration(
                color: context.colorScheme.secondaryContainer,
                borderRadius: BorderRadius.circular(AppRadius.sm),
              ),
              child: Text(count.toString(), style: ts.s12),
            ),
          const Spacer(),
          trailing ?? const Icon(Icons.chevron_right),
        ],
      ),
    ).paddingHorizontal(AppSpace.lg);
  }
}

class ComicHorizontalList extends StatelessWidget {
  const ComicHorizontalList({
    super.key,
    required this.comics,
    this.heroTagPrefix,
    this.onItemTap,
  });

  final List<Comic> comics;
  final String? heroTagPrefix;
  final void Function(Comic comic, int heroID)? onItemTap;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 136,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: comics.length,
        itemBuilder: (context, index) {
          final comic = comics[index];
          final heroID = heroTagPrefix != null
              ? '$heroTagPrefix${comic.id}'.hashCode
              : comic.id.hashCode;
          return SimpleComicTile(
            comic: comic,
            heroID: heroID,
            onTap: onItemTap != null ? () => onItemTap!(comic, heroID) : null,
          ).paddingHorizontal(AppSpace.sm).paddingVertical(2);
        },
      ),
    ).paddingHorizontal(AppSpace.sm).paddingBottom(AppSpace.lg);
  }
}
