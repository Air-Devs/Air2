#import "utils.h"
//
//  BackgroundSettingsViewController.m
//  Amethyst
//
//  Background wallpaper settings implementation
//

#import "BackgroundSettingsViewController.h"
#import "BackgroundManager.h"
#import "ImageCropperViewController.h"
#import "AMEGlassStyle.h"   // ★ [GLASS-STYLE] 界面风格(自动 / 原生 / 液态玻璃)解析层

@interface BackgroundSettingsViewController ()
@property (nonatomic, strong) NSArray<NSArray *> *sections;
@property (nonatomic, strong) UIImageView *previewImageView;
@property (nonatomic, strong) UISlider *opacitySlider;
@property (nonatomic, weak) UILabel *opacityValueLabel;
@property (nonatomic, weak) UILabel *glassStrengthValueLabel;   // ★ [GLASSUI] 玻璃强度数值标签
@end

@implementation BackgroundSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    
    self.title = localize(@"i18n_str_53", nil);
    
    // Set transparent background if global background is active
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
    } else {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
    }
    
    // Setup table view
    self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
    self.tableView.tableFooterView = [[UIView alloc] init];
    // ★ [GLASS-STYLE] 「界面风格」页脚是多行说明 ⇒ 走自适应高度(否则多行文案被截/挤)
    self.tableView.sectionFooterHeight = UITableViewAutomaticDimension;
    
    // Setup preview header
    [self setupPreviewHeader];
    
    // Setup sections
    [self setupSections];
    
    // ★ [GLASSUI] 玻璃设置回读:开关/强度由 BackgroundManager 在 init 时从 NSUserDefaults 载入
    //   (键 background_glass_rim_enabled / background_glass_rim_strength,默认 开 / 1.0)。
    //   本页不另存一份本地状态 —— UISwitch/UISlider 在 cellForRowAtIndexPath 里每次都按共享实例
    //   的值同步(并在滑块 setter 里夹紧),所以「当前值」始终与设置一致。
    
    // Add close button
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                           target:self
                                                                                           action:@selector(closeTapped)];

    // 适配自定义启动器背景：将当前视图控制器透明化，让全局背景（图片/视频）能够透出显示。
    // 即使本页是背景设置页本身，也需要透明化以实时预览背景效果。
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];

    // 监听背景 UI 效果变化通知：当用户在背景设置中切换毛玻璃/半透明或调整透明度时，
    // 重新调用 makeViewControllerTransparent 以应用最新的视觉效果，保证背景始终正确透出。
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(reapplyBackgroundEffect)
                                                 name:@"BackgroundUIEffectChanged"
                                               object:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updatePreview];
    [self.tableView reloadData];
    
    // Maintain transparency
    if ([[BackgroundManager sharedManager] hasBackground]) {
        self.view.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundColor = [UIColor clearColor];
        self.tableView.backgroundView = nil;
    }
}

- (void)setupPreviewHeader {
    UIView *headerView = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 200)];
    
    // Transparent header if background is active
    if ([[BackgroundManager sharedManager] hasBackground]) {
        headerView.backgroundColor = [UIColor clearColor];
    } else {
        headerView.backgroundColor = [UIColor secondarySystemBackgroundColor];
    }
    
    // Preview image view
    self.previewImageView = [[UIImageView alloc] initWithFrame:CGRectMake(16, 16, headerView.bounds.size.width - 32, 168)];
    self.previewImageView.contentMode = UIViewContentModeScaleAspectFill;
    self.previewImageView.clipsToBounds = YES;
    self.previewImageView.layer.cornerRadius = 12;
    self.previewImageView.layer.cornerCurve = kCACornerCurveContinuous;   // ★ [CORNER-FIX] 连续圆角(与系统卡片一致)
    self.previewImageView.backgroundColor = [UIColor tertiarySystemBackgroundColor];
    self.previewImageView.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    
    // Add placeholder label
    UILabel *placeholderLabel = [[UILabel alloc] init];
    placeholderLabel.text = localize(@"i18n_str_54", nil);
    placeholderLabel.textColor = [UIColor secondaryLabelColor];
    placeholderLabel.font = [UIFont systemFontOfSize:16];
    placeholderLabel.textAlignment = NSTextAlignmentCenter;
    placeholderLabel.tag = 100;
    placeholderLabel.frame = self.previewImageView.bounds;
    placeholderLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.previewImageView addSubview:placeholderLabel];
    
    [headerView addSubview:self.previewImageView];
    
    self.tableView.tableHeaderView = headerView;
}

- (void)updatePreview {
    BackgroundManager *manager = [BackgroundManager sharedManager];
    UIImage *preview = [manager backgroundPreview];
    
    if (preview) {
        self.previewImageView.image = preview;
        UILabel *placeholder = (UILabel *)[self.previewImageView viewWithTag:100];
        placeholder.hidden = YES;
    } else if ([manager hasVideoBackground]) {
        self.previewImageView.image = nil;
        UILabel *placeholder = (UILabel *)[self.previewImageView viewWithTag:100];
        placeholder.hidden = NO;
        placeholder.text = localize(@"i18n_str_55", nil);
    } else {
        self.previewImageView.image = nil;
        UILabel *placeholder = (UILabel *)[self.previewImageView viewWithTag:100];
        placeholder.hidden = NO;
        placeholder.text = localize(@"i18n_str_56", nil);
    }
}

- (void)setupSections {
    // Sections: [UI效果设置], [选择背景类型], [图片背景, 视频背景], [恢复默认背景, 清除背景]
    self.sections = @[
        @[localize(@"i18n_str_57", nil), localize(@"i18n_str_1296", nil), localize(@"i18n_str_1297", nil)],
        @[localize(@"i18n_str_60", nil)],
        @[localize(@"i18n_str_61", nil), localize(@"i18n_str_55", nil)],
        @[localize(@"i18n_str_62", nil), localize(@"i18n_str_63", nil)],
        // ★ [GLASSUI] 玻璃效果:row0=高光开关(UISwitch),row1=强度滑块(UISlider,0…1)
        // ★ [GLASS-STYLE] 本 section 现在叫「界面风格」:row0=界面风格(自动/原生/液态玻璃),
        //   row1=高光开关(UISwitch),row2=强度滑块(UISlider,0…1)。
        //   ★ 整合而非并列:原生风格下高光开关/强度自动置灰 ⇒ 不会出现「两套互相矛盾的开关」。
        @[localize(@"preference.title.glass_style", nil),
          localize(@"preference.title.glass_handdrawn", nil),
          localize(@"preference.title.glass_strength", nil)]
    ];
}

- (void)closeTapped {
    [self dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - Table View Data Source

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
    return self.sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
    // 如果没有自定义背景，隐藏UI效果设置部分
    if (section == 0 && ![[BackgroundManager sharedManager] hasBackground]) {
        return 0;
    }
    return [self.sections[section] count];
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
    if (section == 0 && ![[BackgroundManager sharedManager] hasBackground]) {
        return nil;
    }
    return self.sections[section][0];
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    static NSString *cellIdentifier = @"BackgroundCell";
    static NSString *sliderCellIdentifier = @"SliderCell";
    static NSString *blurSliderCellIdentifier = @"BlurSliderCell";
    
    BackgroundManager *manager = [BackgroundManager sharedManager];
    BOOL hasBackground = [manager hasBackground];
    
    // UI效果设置部分
    if (indexPath.section == 0 && hasBackground) {
        if (indexPath.row == 0) {
            // UI效果选择
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:cellIdentifier];
            }
            
            cell.textLabel.text = localize(@"i18n_str_57", nil);
            
            NSString *effectName = manager.uiEffect == BackgroundUIEffectBlur ? localize(@"i18n_str_2017", nil) : localize(@"i18n_str_65", nil);
            cell.detailTextLabel.text = effectName;
            cell.imageView.image = [UIImage systemImageNamed:@"rectangle.split.3x3"];
            cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
            
            [self styleCell:cell hasBackground:hasBackground];
            return cell;
            
        } else if (indexPath.row == 1) {
            // 透明度滑块
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:sliderCellIdentifier];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:sliderCellIdentifier];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                
                // 创建滑块
                UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 0, cell.bounds.size.width - 120, 30)];
                slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                slider.minimumValue = 0.1f;
                slider.maximumValue = 1.0f;
                slider.tag = 200;
                [slider addTarget:self action:@selector(opacitySliderChanged:) forControlEvents:UIControlEventValueChanged];
                
                // 创建数值标签
                UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(cell.bounds.size.width - 80, 0, 60, 30)];
                valueLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
                valueLabel.textAlignment = NSTextAlignmentRight;
                valueLabel.tag = 201;
                valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
                
                [cell.contentView addSubview:slider];
                [cell.contentView addSubview:valueLabel];
                
                cell.contentView.layoutMargins = UIEdgeInsetsMake(8, 16, 8, 16);
            }
            
            [self styleCell:cell hasBackground:hasBackground];
            
            UISlider *slider = [cell.contentView viewWithTag:200];
            slider.value = manager.uiOpacity;
            
            UILabel *valueLabel = [cell.contentView viewWithTag:201];
            valueLabel.text = [NSString stringWithFormat:@"%.0f%%", manager.uiOpacity * 100];
            valueLabel.textColor = hasBackground ? [UIColor whiteColor] : [UIColor labelColor];
            self.opacityValueLabel = valueLabel;
            
            cell.textLabel.text = nil;
            cell.imageView.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
            
            return cell;
            
        } else if (indexPath.row == 2) {
            // 模糊程度滑块
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:blurSliderCellIdentifier];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:blurSliderCellIdentifier];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                
                // 创建滑块
                UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 0, cell.bounds.size.width - 120, 30)];
                slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
                slider.minimumValue = 0.0f;
                slider.maximumValue = 1.0f;
                slider.tag = 300;
                [slider addTarget:self action:@selector(blurIntensitySliderChanged:) forControlEvents:UIControlEventValueChanged];
                
                // 创建数值标签
                UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(cell.bounds.size.width - 80, 0, 60, 30)];
                valueLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
                valueLabel.textAlignment = NSTextAlignmentRight;
                valueLabel.tag = 301;
                valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
                
                [cell.contentView addSubview:slider];
                [cell.contentView addSubview:valueLabel];
                
                cell.contentView.layoutMargins = UIEdgeInsetsMake(8, 16, 8, 16);
            }
            
            [self styleCell:cell hasBackground:hasBackground];
            
            UISlider *slider = [cell.contentView viewWithTag:300];
            slider.value = manager.blurIntensity;
            
            UILabel *valueLabel = [cell.contentView viewWithTag:301];
            valueLabel.text = [NSString stringWithFormat:@"%.0f%%", manager.blurIntensity * 100];
            valueLabel.textColor = hasBackground ? [UIColor whiteColor] : [UIColor labelColor];
            
            cell.textLabel.text = nil;
            cell.imageView.image = [UIImage systemImageNamed:@"slider.horizontal.3"];
            
            return cell;
        }
    }
    
    // ★ [GLASS-STYLE] 「界面风格」section:row0=风格(自动/原生/液态玻璃) · row1=高光开关 · row2=强度滑块
    if (indexPath.section == 4) {
        // ★ [GLASS-STYLE] row0:界面风格分段控件(iOS<26 ⇒「液态玻璃」置灰 + 页脚说明)
        if (indexPath.row == 0) {
            static NSString *glassStyleCellIdentifier = @"GlassStyleCell";
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:glassStyleCellIdentifier];
            UISegmentedControl *seg = nil;
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:glassStyleCellIdentifier];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                seg = [[UISegmentedControl alloc] initWithItems:@[
                    localize(@"preference.style.auto", nil),
                    localize(@"preference.style.native", nil),
                    localize(@"preference.style.liquid", nil),
                ]];
                seg.tag = 420;   // ★ [GLASS-STYLE]
                [seg addTarget:self action:@selector(glassStyleChanged:) forControlEvents:UIControlEventValueChanged];
                // ★ 平铺进内容区(受 layoutMarginsGuide 约束)⇒ iPhone 320pt 竖屏 / iPad 1366pt 横屏都不被裁
                seg.translatesAutoresizingMaskIntoConstraints = NO;
                [cell.contentView addSubview:seg];
                UILayoutGuide *ameMarginGuide = cell.contentView.layoutMarginsGuide;
                [NSLayoutConstraint activateConstraints:@[
                    [seg.leadingAnchor  constraintEqualToAnchor:ameMarginGuide.leadingAnchor],
                    [seg.trailingAnchor constraintEqualToAnchor:ameMarginGuide.trailingAnchor],
                    [seg.centerYAnchor  constraintEqualToAnchor:cell.contentView.centerYAnchor],
                    [seg.heightAnchor    constraintGreaterThanOrEqualToConstant:32.0],
                ]];
                cell.accessoryView = nil;
            } else {
                seg = (UISegmentedControl *)[cell.contentView viewWithTag:420];
            }
            cell.textLabel.text = nil;
            cell.imageView.image = nil;
            if ([seg isKindOfClass:[UISegmentedControl class]]) {
                // 本地化文案(切语言后 reloadData 会重设)+ 回读当前配置(未设置过 ⇒ 自动)
                [seg setTitle:localize(@"preference.style.auto", nil)   forSegmentAtIndex:AMEGlassStyleAuto];
                [seg setTitle:localize(@"preference.style.native", nil) forSegmentAtIndex:AMEGlassStyleNative];
                [seg setTitle:localize(@"preference.style.liquid", nil) forSegmentAtIndex:AMEGlassStyleLiquid];
                seg.selectedSegmentIndex = (NSInteger)AMEGlassStyleConfigured();
                // ★ iOS < 26(或系统拿不到 UIGlassEffect):「液态玻璃」置灰不可选
                [seg setEnabled:AMEGlassStyleSystemSupportsLiquid() forSegmentAtIndex:AMEGlassStyleLiquid];
            }
            [self styleCell:cell hasBackground:hasBackground];
            return cell;
        }

        // ★ [GLASS-STYLE] row1:自绘高光开关(默认关 —— 群主口径「纯液态」;仅系统支持液态玻璃时可开)
        if (indexPath.row == 1) {
            static NSString *glassSwitchCellIdentifier = @"GlassSwitchCell";   // ★ [GLASSUI]
            UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:glassSwitchCellIdentifier];
            if (!cell) {
                cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:glassSwitchCellIdentifier];
                cell.selectionStyle = UITableViewCellSelectionStyleNone;
                UISwitch *sw = [[UISwitch alloc] init];
                sw.tag = 400;   // ★ [GLASSUI]
                [sw addTarget:self action:@selector(glassSwitchChanged:) forControlEvents:UIControlEventValueChanged];
                cell.accessoryView = sw;
            }
            cell.textLabel.text = self.sections[indexPath.section][indexPath.row];
            cell.imageView.image = [UIImage systemImageNamed:@"sparkles"];
            // ★ [GLASS-LIQUID] 开关 = 「自绘高光」是否叠加(默认关)。只有系统支持液态玻璃(iOS≥26)才可开。
            BOOL ameLiquidOK = AMEGlassStyleSystemSupportsLiquid();
            UISwitch *sw = (UISwitch *)cell.accessoryView;
            if ([sw isKindOfClass:[UISwitch class]]) {
                sw.on = AMEGlassStyleHandDrawnOverlayEnabled();   // 回读真实开关(不再混入 glassRimEnabled)
                sw.enabled = ameLiquidOK;
            }
            cell.textLabel.enabled = ameLiquidOK;
            cell.imageView.alpha = ameLiquidOK ? 1.0 : 0.35;
            [self styleCell:cell hasBackground:hasBackground];
            return cell;
        }

        // ★ [GLASS-STYLE] row2:高光强度滑块(原生风格下同样置灰)
        static NSString *glassSliderCellIdentifier = @"GlassSliderCell";   // ★ [GLASSUI]
        UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:glassSliderCellIdentifier];
        if (!cell) {
            cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:glassSliderCellIdentifier];
            cell.selectionStyle = UITableViewCellSelectionStyleNone;

            UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 0, cell.bounds.size.width - 120, 30)];
            slider.autoresizingMask = UIViewAutoresizingFlexibleWidth;
            slider.minimumValue = 0.0f;
            slider.maximumValue = 1.0f;   // ★ 与 BackgroundManager 的 clamp 区间一致
            slider.tag = 410;             // ★ [GLASSUI]
            [slider addTarget:self action:@selector(glassStrengthSliderChanged:) forControlEvents:UIControlEventValueChanged];

            UILabel *valueLabel = [[UILabel alloc] initWithFrame:CGRectMake(cell.bounds.size.width - 80, 0, 60, 30)];
            valueLabel.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
            valueLabel.textAlignment = NSTextAlignmentRight;
            valueLabel.tag = 411;         // ★ [GLASSUI]
            valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];

            [cell.contentView addSubview:slider];
            [cell.contentView addSubview:valueLabel];
            cell.contentView.layoutMargins = UIEdgeInsetsMake(8, 16, 8, 16);
        }

        [self styleCell:cell hasBackground:hasBackground];
        cell.textLabel.text = nil;
        cell.imageView.image = [UIImage systemImageNamed:@"slider.horizontal.3"];

        BOOL ameHandOn = AMEGlassStyleHandDrawnOverlayEnabled();
        BOOL ameSliderEnabled = AMEGlassStyleSystemSupportsLiquid() && ameHandOn;
        UISlider *slider = [cell.contentView viewWithTag:410];
        if ([slider isKindOfClass:[UISlider class]]) {
            slider.value = manager.glassRimStrength;      // 回读当前值(已夹紧)
            slider.enabled = ameSliderEnabled;            // 未开「自绘高光」或系统不支持 ⇒ 置灰(HIG)
        }
        UILabel *valueLabel = [cell.contentView viewWithTag:411];
        if ([valueLabel isKindOfClass:[UILabel class]]) {
            valueLabel.text = [NSString stringWithFormat:@"%.0f%%", manager.glassRimStrength * 100];
            valueLabel.textColor = hasBackground ? [UIColor whiteColor] : [UIColor labelColor];
            valueLabel.alpha = ameSliderEnabled ? 1.0 : 0.35;
        }
        cell.imageView.alpha = ameSliderEnabled ? 1.0 : 0.35;
        self.glassStrengthValueLabel = valueLabel;
        return cell;
    }

    // 其他部分
    UITableViewCell *cell = [tableView dequeueReusableCellWithIdentifier:cellIdentifier];
    if (!cell) {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:cellIdentifier];
    }
    
    NSString *title = self.sections[indexPath.section][indexPath.row];
    cell.textLabel.text = title;
    cell.detailTextLabel.text = nil;
    
    [self styleCell:cell hasBackground:hasBackground];
    
    if (indexPath.section == 1) {
        // 选择背景类型标题
        cell.textLabel.textColor = [UIColor secondaryLabelColor];
        cell.imageView.image = nil;
        cell.accessoryType = UITableViewCellAccessoryNone;
    } else if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            cell.imageView.image = [UIImage systemImageNamed:@"photo"];
            cell.accessoryType = [manager hasImageBackground] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        } else if (indexPath.row == 1) {
            cell.imageView.image = [UIImage systemImageNamed:@"film"];
            cell.accessoryType = [manager hasVideoBackground] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
        }
    } else if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            // 恢复默认背景
            cell.imageView.image = [UIImage systemImageNamed:@"arrow.counterclockwise"];
            cell.textLabel.textColor = [UIColor systemBlueColor];
            cell.accessoryType = UITableViewCellAccessoryNone;
        } else if (indexPath.row == 1) {
            // 清除背景
            cell.imageView.image = [UIImage systemImageNamed:@"xmark.circle"];
            cell.textLabel.textColor = [UIColor systemRedColor];
            cell.accessoryType = UITableViewCellAccessoryNone;
        }
    }
    
    return cell;
}

// ★ [GLASS-STYLE] 「界面风格」页脚:说明自动判定结果 / 置灰原因(原生风格 / 自绘高光状态)
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    if (section == 4) {
        NSMutableString *ameFooter = [NSMutableString string];
        [ameFooter appendString:AMEGlassStyleSystemSupportsLiquid()
                                 ? localize(@"preference.style.footer.supported", nil)
                                 : localize(@"preference.style.footer.unsupported", nil)];
        if (!AMEGlassStyleSystemSupportsLiquid()) {
            // iOS < 26:系统没有液态玻璃 ⇒ 自绘开关/强度不可用
            [ameFooter appendFormat:@"\n%@", localize(@"preference.style.footer.native", nil)];
        } else if (AMEGlassStyleHandDrawnOverlayEnabled()) {
            // 显式打开自绘高光
            [ameFooter appendFormat:@"\n%@", localize(@"preference.style.footer.handdrawn", nil)];
        } else {
            // 默认:纯系统材质(群主口径「纯液态」)
            [ameFooter appendFormat:@"\n%@", localize(@"preference.style.footer.pure", nil)];
        }
        return ameFooter;
    }
    return nil;
}

// ★ [GLASS-STYLE] 页脚是多行说明 ⇒ 自适应高度(iOS 11+ 对 titleForFooterInSection 支持)
- (CGFloat)tableView:(UITableView *)tableView heightForFooterInSection:(NSInteger)section {
    return UITableViewAutomaticDimension;
}

- (void)styleCell:(UITableViewCell *)cell hasBackground:(BOOL)hasBackground {
    if (hasBackground) {
        [[BackgroundManager sharedManager] applyEffectToCell:cell];
        cell.textLabel.textColor = [UIColor whiteColor];
    } else {
        cell.backgroundColor = [UIColor secondarySystemBackgroundColor];
        cell.textLabel.textColor = [UIColor labelColor];
    }
}

#pragma mark - Slider Actions

- (void)opacitySliderChanged:(UISlider *)slider {
    CGFloat value = slider.value;
    [BackgroundManager sharedManager].uiOpacity = value;
    
    self.opacityValueLabel.text = [NSString stringWithFormat:@"%.0f%%", value * 100];
    
    // 实时刷新UI效果
    [[BackgroundManager sharedManager] refreshUIEffect];
}

- (void)blurIntensitySliderChanged:(UISlider *)slider {
    CGFloat value = slider.value;
    [BackgroundManager sharedManager].blurIntensity = value;
    
    // 更新标签显示
    UITableViewCell *cell = (UITableViewCell *)slider.superview.superview;
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        UILabel *valueLabel = [cell.contentView viewWithTag:301];
        valueLabel.text = [NSString stringWithFormat:@"%.0f%%", value * 100];
    }
    
    // 实时刷新UI效果
    [[BackgroundManager sharedManager] refreshUIEffect];
}

#pragma mark - ★ [GLASSUI] 玻璃开关 / 强度

// 开关:开 = 按当前强度恢复高光;关 = 摘除高光(AmeDetachGlassRim 那条路径)。
// setter 内已做「持久化 + 写全局强度 + 立即重刷」,这里只同步同页控件的可用态。
- (void)glassSwitchChanged:(UISwitch *)sw {
    // ★ [GLASS-LIQUID] 开关 = 「自绘高光」是否叠加(默认关;群主口径「纯液态」)。
    //   写入单一真相源键(background_glass_handdrawn)+ 广播 AMEGlassStyleChanged ⇒ BackgroundManager 立即按新值重刷。
    [BackgroundManager sharedManager].glassRimEnabled = sw.on;      // 兼容既有全局强度收敛(强度 0 ⇒ 不刷)
    AMEGlassStyleSetHandDrawnOverlayEnabled(sw.on);

    // row2 滑块的可用态 + 本 section 页脚说明都要跟着开关变。
    // ★ 延后一个 runloop:本方法由本 section 内的 UISwitch 触发,触摸派发中同步 reload 会换掉该控件。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:4]
                      withRowAnimation:UITableViewRowAnimationNone];
    });
}

// ★ [GLASS-STYLE] 界面风格(自动 / 原生 / 液态玻璃)
//   分段控件的 index 与 AMEGlassStyle 枚举一一对应(0=自动 1=原生 2=液态玻璃)。
//   AMEGlassStyleSetConfigured 内部:① 写 NSUserDefaults(键 background_glass_style,
//   与同 section 的高光开关/强度同库)② 广播 AMEGlassStyleChangedNotification ⇒ BackgroundManager 立即按新风格重刷;
//   iOS<26 时该分段已置灰,这里再兜一次「只允许 native」,保证老设备不会被写进 liquid。
- (void)glassStyleChanged:(UISegmentedControl *)seg {
    AMEGlassStyle picked = AMEGlassStyleEnumFromString(AMEGlassStyleStringFromEnum((AMEGlassStyle)seg.selectedSegmentIndex));
    if (picked == AMEGlassStyleLiquid && !AMEGlassStyleSystemSupportsLiquid()) {
        picked = AMEGlassStyleNative;   // ★ iOS<26 强制原生
    }
    AMEGlassStyleSetConfigured(picked);
    seg.selectedSegmentIndex = (NSInteger)AMEGlassStyleConfigured();

    // 重设本 section:开关/滑块的可用态、页脚说明都要跟着风格变。
    // ★ 延后一个 runloop:本方法是由【本 section 内】的分段控件自己触发的,
    //   在触摸派发过程中同步 reload 会把这个控件连同 cell 一起换掉(偶发丢高亮/手势被打断)。
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.tableView reloadSections:[NSIndexSet indexSetWithIndex:4]
                      withRowAnimation:UITableViewRowAnimationNone];
    });
}

// 强度:setter 内 clamp(0…1)+ 持久化 + 立即重刷;这里只更新数值标签。
- (void)glassStrengthSliderChanged:(UISlider *)slider {
    [BackgroundManager sharedManager].glassRimStrength = slider.value;

    UITableViewCell *cell = (UITableViewCell *)slider.superview.superview;
    if ([cell isKindOfClass:[UITableViewCell class]]) {
        UILabel *valueLabel = [cell.contentView viewWithTag:411];
        valueLabel.text = [NSString stringWithFormat:@"%.0f%%", [BackgroundManager sharedManager].glassRimStrength * 100];
    }
}

#pragma mark - Table View Delegate

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    
    BackgroundManager *manager = [BackgroundManager sharedManager];
    BOOL hasBackground = [manager hasBackground];
    
    // UI效果设置部分
    if (indexPath.section == 0 && hasBackground) {
        if (indexPath.row == 0) {
            [self showUIEffectPicker];
        }
        return;
    }
    
    // ★ [GLASSUI] 点整行也能切换玻璃开关(与点 UISwitch 等效;HIG 习惯)
    // ★ [GLASS-STYLE] row0(界面风格)由分段控件自己处理,不参与整行点击;开关移到 row1。
    if (indexPath.section == 4) {
        if (indexPath.row == 1) {
            UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:indexPath];
            UISwitch *sw = (UISwitch *)cell.accessoryView;
            if ([sw isKindOfClass:[UISwitch class]] && sw.enabled) {
                [sw setOn:!sw.on animated:YES];
                [self glassSwitchChanged:sw];
            }
        }
        return;
    }
    
    if (indexPath.section == 2) {
        if (indexPath.row == 0) {
            [self selectImageBackground];
        } else if (indexPath.row == 1) {
            [self selectVideoBackground];
        }
    } else if (indexPath.section == 3) {
        if (indexPath.row == 0) {
            [self restoreDefaultBackground];
        } else if (indexPath.row == 1) {
            [self clearBackground];
        }
    }
}

- (void)showUIEffectPicker {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_66", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    BackgroundManager *manager = [BackgroundManager sharedManager];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_67", nil)
                                              style:manager.uiEffect == BackgroundUIEffectBlur ? UIAlertActionStyleDefault : UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        manager.uiEffect = BackgroundUIEffectBlur;
        [manager refreshUIEffect];
        [self.tableView reloadData];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundUIEffectChanged" object:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_68", nil)
                                              style:manager.uiEffect == BackgroundUIEffectTranslucent ? UIAlertActionStyleDefault : UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        manager.uiEffect = BackgroundUIEffectTranslucent;
        [manager refreshUIEffect];
        [self.tableView reloadData];
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundUIEffectChanged" object:nil];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]];
        alert.popoverPresentationController.sourceView = cell ?: self.view;
        alert.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Background Selection

- (void)selectImageBackground {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_70", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_71", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self openPhotoLibraryForImage];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_72", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self openDocumentPickerForImage];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:2]];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)selectVideoBackground {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_73", nil)
                                                                   message:nil
                                                            preferredStyle:UIAlertControllerStyleActionSheet];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_71", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self openPhotoLibraryForVideo];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_72", nil)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction * _Nonnull action) {
        [self openDocumentPickerForVideo];
    }]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPad) {
        UITableViewCell *cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:2]];
        alert.popoverPresentationController.sourceView = cell;
        alert.popoverPresentationController.sourceRect = cell.bounds;
    }
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)restoreDefaultBackground {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_62", nil)
                                                                   message:localize(@"i18n_str_74", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_75", nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * _Nonnull action) {
        // 清除背景
        [[BackgroundManager sharedManager] clearBackground];
        
        // 重置UI效果设置
        BackgroundManager *manager = [BackgroundManager sharedManager];
        manager.uiEffect = BackgroundUIEffectBlur;
        manager.uiOpacity = 0.7;
        
        [self updatePreview];
        [self.tableView reloadData];
        
        // 恢复默认背景色
        self.view.backgroundColor = [UIColor systemBackgroundColor];
        self.tableView.backgroundColor = [UIColor systemBackgroundColor];
        self.tableView.backgroundView = nil;
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundChanged" object:nil];
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)clearBackground {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_63", nil)
                                                                   message:localize(@"i18n_str_76", nil)
                                                            preferredStyle:UIAlertControllerStyleAlert];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"resman.common.cancel", nil)
                                              style:UIAlertActionStyleCancel
                                            handler:nil]];
    
    [alert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_77", nil)
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction * _Nonnull action) {
        [[BackgroundManager sharedManager] clearBackground];
        [self updatePreview];
        [self.tableView reloadData];
        
        // Restore default background color
        self.view.backgroundColor = [UIColor systemBackgroundColor];
        self.tableView.backgroundColor = [UIColor systemBackgroundColor];
        
        [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundChanged" object:nil];
    }]];
    
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - Image Picker

- (void)openPhotoLibraryForImage {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.image"];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openPhotoLibraryForVideo {
    UIImagePickerController *picker = [[UIImagePickerController alloc] init];
    picker.sourceType = UIImagePickerControllerSourceTypePhotoLibrary;
    picker.mediaTypes = @[@"public.movie"];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - Document Picker

- (void)openDocumentPickerForImage {
    NSArray<UTType *> *contentTypes = @[
        UTTypeJPEG,
        UTTypePNG,
        UTTypeImage
    ];
    
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)openDocumentPickerForVideo {
    NSArray<UTType *> *contentTypes = @[
        UTTypeMovie,
        UTTypeVideo,
        UTTypeMPEG4Movie
    ];
    
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:contentTypes];
    picker.delegate = self;
    picker.allowsMultipleSelection = NO;
    [self presentViewController:picker animated:YES completion:nil];
}

#pragma mark - UIImagePickerControllerDelegate

- (void)imagePickerController:(UIImagePickerController *)picker didFinishPickingMediaWithInfo:(NSDictionary<UIImagePickerControllerInfoKey,id> *)info {
    NSString *mediaType = info[UIImagePickerControllerMediaType];
    
    if ([mediaType isEqualToString:@"public.image"]) {
        UIImage *image = info[UIImagePickerControllerOriginalImage];
        [picker dismissViewControllerAnimated:YES completion:^{
            [self processSelectedImage:image];
        }];
    } else if ([mediaType isEqualToString:@"public.movie"]) {
        NSURL *videoURL = info[UIImagePickerControllerMediaURL];
        [picker dismissViewControllerAnimated:YES completion:^{
            [self processSelectedVideo:videoURL];
        }];
    }
}

- (void)imagePickerControllerDidCancel:(UIImagePickerController *)picker {
    [picker dismissViewControllerAnimated:YES completion:nil];
}

#pragma mark - UIDocumentPickerDelegate

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    if (urls.count == 0) return;
    
    NSURL *url = urls.firstObject;
    NSString *extension = url.pathExtension.lowercaseString;
    
    if ([@[@"jpg", @"jpeg", @"png", @"heic"] containsObject:extension]) {
        // ★ [ISSUE-FIX] #92（同类）：Document Picker 返回的是 security-scoped URL，
        //   未取用作用域时 imageWithContentsOfFile: 返回 nil（表现为「选图无反应」）。
        BOOL ame92Scoped = [url startAccessingSecurityScopedResource];
        UIImage *image = [UIImage imageWithContentsOfFile:url.path];
        if (ame92Scoped) [url stopAccessingSecurityScopedResource];
        if (image) [self processSelectedImage:image];
    } else if ([@[@"mp4", @"mov", @"m4v"] containsObject:extension]) {
        [self processSelectedVideo:url];
    }
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    // Cancelled
}

#pragma mark - Process Selection

- (void)processSelectedImage:(UIImage *)image {
    if (!image) return;
    
    UIAlertController *processingAlert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_78", nil)
                                                                             message:localize(@"i18n_str_79", nil)
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:processingAlert animated:YES completion:nil];
    
    [[BackgroundManager sharedManager] setImageBackground:image completion:^(BOOL success, NSError * _Nullable error) {
        [processingAlert dismissViewControllerAnimated:YES completion:^{
            if (success) {
                [self updatePreview];
                [self.tableView reloadData];
                
                // Apply transparency
                self.view.backgroundColor = [UIColor clearColor];
                self.tableView.backgroundColor = [UIColor clearColor];
                self.tableView.backgroundView = nil;
                
                [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundChanged" object:nil];
                
                UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_80", nil)
                                                                                      message:localize(@"i18n_str_81", nil)
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [successAlert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:successAlert animated:YES completion:nil];
            } else {
                UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_42", nil)
                                                                                    message:error.localizedDescription ?: localize(@"i18n_str_82", nil)
                                                                             preferredStyle:UIAlertControllerStyleAlert];
                [errorAlert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:errorAlert animated:YES completion:nil];
            }
        }];
    }];
}

- (void)processSelectedVideo:(NSURL *)videoURL {
    if (!videoURL) return;
    
    UIAlertController *processingAlert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_78", nil)
                                                                             message:localize(@"i18n_str_83", nil)
                                                                      preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:processingAlert animated:YES completion:nil];
    
    [[BackgroundManager sharedManager] setVideoBackgroundWithURL:videoURL completion:^(BOOL success, NSError * _Nullable error) {
        [processingAlert dismissViewControllerAnimated:YES completion:^{
            if (success) {
                [self updatePreview];
                [self.tableView reloadData];
                
                // Apply transparency
                self.view.backgroundColor = [UIColor clearColor];
                self.tableView.backgroundColor = [UIColor clearColor];
                self.tableView.backgroundView = nil;
                
                [[NSNotificationCenter defaultCenter] postNotificationName:@"BackgroundChanged" object:nil];
                
                UIAlertController *successAlert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_80", nil)
                                                                                      message:localize(@"i18n_str_84", nil)
                                                                               preferredStyle:UIAlertControllerStyleAlert];
                [successAlert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:successAlert animated:YES completion:nil];
            } else {
                UIAlertController *errorAlert = [UIAlertController alertControllerWithTitle:localize(@"i18n_str_42", nil)
                                                                                    message:error.localizedDescription ?: localize(@"i18n_str_85", nil)
                                                                             preferredStyle:UIAlertControllerStyleAlert];
                [errorAlert addAction:[UIAlertAction actionWithTitle:localize(@"i18n_str_44", nil) style:UIAlertActionStyleDefault handler:nil]];
                [self presentViewController:errorAlert animated:YES completion:nil];
            }
        }];
    }];
}

/// 重新应用背景效果：当 BackgroundUIEffectChanged 通知到达时调用，
/// 通过 BackgroundManager 重新设置当前视图控制器的透明度/毛玻璃效果，
/// 并手动清空 tableView 背景与 backgroundView，确保全局背景能够正常透出。
- (void)reapplyBackgroundEffect {
    [[BackgroundManager sharedManager] makeViewControllerTransparent:self];
    self.tableView.backgroundColor = [UIColor clearColor];
    self.tableView.backgroundView = nil;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

@end