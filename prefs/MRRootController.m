#import <UIKit/UIKit.h>
#import "../ReadPreferences.h"
@interface PSViewController : UIViewController
@end
@interface MRTableController : UITableViewController
@end
@implementation MRTableController
- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView { (void)tableView; return 2; }
- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section { (void)tableView; (void)section; return 1; }
- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
    (void)tableView;
    return section == 0 ? @"Automatically marks muted Messages chats as read. Changes apply immediately; no respring needed." : @"Mute chats using Hide Alerts in Messages. Enabled read receipts may be sent.";
}
- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
    (void)tableView;
    UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
    if (indexPath.section == 0) {
        cell.textLabel.text = @"Enabled";
        UISwitch *toggle = [[UISwitch alloc] init];
        toggle.on = MREnabled();
        toggle.accessibilityLabel = @"Enabled";
        [toggle addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
        cell.accessoryView = toggle;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else {
        cell.textLabel.text = @"GitHub Repository";
        cell.textLabel.textColor = self.view.tintColor;
        cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    }
    return cell;
}
- (void)toggleChanged:(UISwitch *)toggle { MRSetEnabled(toggle.on); }
- (void)viewWillAppear:(BOOL)animated { [super viewWillAppear:animated]; [self.tableView reloadData]; }
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section == 1) {
        [UIApplication.sharedApplication openURL:[NSURL URLWithString:@"https://github.com/551UK/Mark-Muted-Chats-Read-16"] options:@{} completionHandler:nil];
    }
}
@end
@interface MRRootController : PSViewController
@property(nonatomic, strong) MRTableController *settingsTable;
@end
@implementation MRRootController
- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"Mark Muted Chats Read 16";
    self.settingsTable = [[MRTableController alloc] initWithStyle:UITableViewStyleInsetGrouped];
    [self addChildViewController:self.settingsTable];
    self.settingsTable.view.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:self.settingsTable.view];
    [NSLayoutConstraint activateConstraints:@[
        [self.settingsTable.view.topAnchor constraintEqualToAnchor:self.view.topAnchor],
        [self.settingsTable.view.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
        [self.settingsTable.view.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
        [self.settingsTable.view.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
    ]];
    [self.settingsTable didMoveToParentViewController:self];
}
@end
