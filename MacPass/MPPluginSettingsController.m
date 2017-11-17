//
//  MPPluginSettingsController.m
//  MacPass
//
//  Created by Michael Starke on 09/11/15.
//  Copyright © 2015 HicknHack Software GmbH. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

#import "MPPluginSettingsController.h"
#import "MPPluginTabelCellView.h"
#import "MPPluginHost.h"
#import "MPPlugin.h"

#import "MPConstants.h"
#import "MPSettingsHelper.h"

#import "NSApplication+MPAdditions.h"

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSUInteger, MPPluginSegmentType) {
  MPAddPluginSegment = 0,
  MPRemovePluginSegment = 1
};

@interface MPPluginSettingsController () <NSTableViewDataSource, NSTableViewDelegate>

@property (weak) IBOutlet NSTableView *pluginTableView;
@property (weak) IBOutlet NSView *settingsView;
@property (weak) IBOutlet NSButton *loadInsecurePlugsinCheckButton;
@property (weak) IBOutlet NSSegmentedControl *addRemovePluginsControl;

@end

@implementation MPPluginSettingsController

- (NSString *)nibName {
  return @"PluginSettings";
}

- (NSString *)identifier {
  return @"Plugins";
}

- (NSImage *)image {
  return [[NSWorkspace sharedWorkspace] iconForFileType:@"bundle"];
}

- (NSString *)label {
  return NSLocalizedString(@"PLUGIN_SETTINGS", "Label for plugin settings tab");
}

- (void)viewDidLoad {
  self.pluginTableView.delegate = self;
  self.pluginTableView.dataSource = self;
  [self.addRemovePluginsControl setEnabled:NO forSegment:MPRemovePluginSegment];
  
  [self.loadInsecurePlugsinCheckButton bind:NSValueBinding
                                   toObject:[NSUserDefaultsController sharedUserDefaultsController]
                                withKeyPath:[MPSettingsHelper defaultControllerPathForKey:kMPSettingsKeyLoadUnsecurePlugins]
                                    options:nil];
  [self.pluginTableView registerForDraggedTypes:@[(NSString *)kUTTypeFileURL]];
}

# pragma mark - TableView

- (NSInteger)numberOfRowsInTableView:(NSTableView *)tableView {
  return [MPPluginHost sharedHost].plugins.count;
}

- (NSView *)tableView:(NSTableView *)tableView viewForTableColumn:(NSTableColumn *)tableColumn row:(NSInteger)row {
  MPPlugin *plugin = [self pluginForRow:row];
  MPPluginTabelCellView *view = [tableView makeViewWithIdentifier:tableColumn.identifier owner:nil];
  view.textField.stringValue = [NSString stringWithFormat:@"%@", plugin.name];
  view.addionalTextField.stringValue = [NSString stringWithFormat:NSLocalizedString(@"PLUGIN_VERSION_%@", "Plugin version. Include a %@ placeholder for version string"), plugin.version];
  return view;
}

- (void)showSettingsForPlugin:(MPPlugin *)plugin {
  /* move old one regardless */
  [self.settingsView.subviews.firstObject removeFromSuperview];
  if([plugin conformsToProtocol:@protocol(MPPluginSettings)]) {
    NSAssert([plugin respondsToSelector:@selector(settingsViewController)], @"Required getter for settings on plugins");
    NSViewController *viewController = ((id<MPPluginSettings>)plugin).settingsViewController;
    [self.settingsView addSubview:viewController.view];
    NSDictionary *dict = @{ @"view" : viewController.view,
                            @"table" : self.pluginTableView.enclosingScrollView };
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"H:|[view]|" options:0 metrics:nil views:dict]];
    [self.view addConstraints:[NSLayoutConstraint constraintsWithVisualFormat:@"V:|[view]|" options:0 metrics:nil views:dict]];
  }
}

- (MPPlugin *)pluginForRow:(NSInteger)row {
  NSArray<MPPlugin __kindof *> *plugins = [MPPluginHost sharedHost].plugins;
  if(0 > row || row >= plugins.count) {
    return nil;
  }
  return plugins[row];
}

- (void)tableViewSelectionDidChange:(NSNotification *)notification {
  NSTableView *table = notification.object;
  if(table != self.pluginTableView) {
    return; // wrong tableview
  }
  MPPlugin *plugin = [self pluginForRow:table.selectedRow];
  [self.addRemovePluginsControl setEnabled:(nil != plugin) forSegment:MPRemovePluginSegment];
  [self showSettingsForPlugin:plugin];
}

- (NSDragOperation)tableView:(NSTableView *)tableView validateDrop:(id <NSDraggingInfo>)info proposedRow:(NSInteger)row proposedDropOperation:(NSTableViewDropOperation)dropOperation {
  NSArray *arrayOfURLs = [[info draggingPasteboard] readObjectsForClasses:@[NSURL.class] options:nil];
  if(arrayOfURLs.count != 1) {
    return NO;
  }
  NSURL *pluginURL = arrayOfURLs.firstObject;
  if(!pluginURL.isFileURL) {
    return NO;
  }
  if(![pluginURL.lastPathComponent.pathExtension isEqualToString:kMPPluginFileExtension]) {
    return NO;
  }
  [tableView setDropRow:-1 dropOperation:NSTableViewDropOn];
  return YES;
}

- (BOOL)tableView:(NSTableView *)tableView acceptDrop:(nonnull id<NSDraggingInfo>)info row:(NSInteger)row dropOperation:(NSTableViewDropOperation)dropOperation {
  /* dispatch installation since we do not want to wait for the result */
  if(dropOperation != NSTableViewDropOn) {
    return NO;
  }
  NSPasteboard *draggingPasteboard = [info draggingPasteboard];
  NSArray *arrayOfURLs = [draggingPasteboard readObjectsForClasses:@[NSURL.class] options:nil];
  if(arrayOfURLs.count != 1) {
    return NO;
  }
  dispatch_async(dispatch_get_main_queue(), ^{
    [self _addPlugin:arrayOfURLs.firstObject];
  });
  return YES;
}

#pragma mark - Actions

- (IBAction)browsePlugins:(id)sender {
  [NSWorkspace.sharedWorkspace openURL:[NSApp applicationSupportDirectoryURL:YES]];
}

- (IBAction)addOrRemovePlugin:(id)sender {
  if(sender != self.addRemovePluginsControl) {
    return;
  }
  switch(self.addRemovePluginsControl.selectedSegment) {
    case MPAddPluginSegment:
      [self showAddPluginPanel];
      break;
    case MPRemovePluginSegment:
      [self showRemovePluginAlert];
      break;
    default:
      break;
  }
}

- (void)showAddPluginPanel {
  NSOpenPanel *openPanel = [NSOpenPanel openPanel];
  openPanel.allowedFileTypes = @[kMPPluginFileExtension];
  openPanel.allowsMultipleSelection = NO;
  openPanel.canChooseFiles = YES;
  openPanel.canChooseDirectories = NO;
  openPanel.prompt = NSLocalizedString(@"OPEN_BUTTON_ADD_PLUGIN_OPEN_PANEL", "Open button in the add plugin open panel");
  openPanel.message = NSLocalizedString(@"MESSAGE_ADD_PLUGIN_OPEN_PANEL", "Message in the add plugin open panel");
  [openPanel beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse result) {
    if(NSModalResponseOK) {
      if(openPanel.URLs.count == 1) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 *  NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self _addPlugin:openPanel.URLs.firstObject];
        });
      }
    }
  }];
}

- (void)_addPlugin:(NSURL *)bundleURL {
  NSError *error;
  if(![[MPPluginHost sharedHost] installPluginAtURL:bundleURL error:&error]) {
    [NSApp presentError:error modalForWindow:self.view.window delegate:nil didPresentSelector:NULL contextInfo:NULL];
  }
  else {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = NSLocalizedString(@"ALERT_MESSAGE_TEXT_PLUGIN_INSTALLED_SUGGEST_RESTART", "Alert message text when a plugin was successfully installed");
    alert.informativeText = NSLocalizedString(@"ALERT_INFORMATIVE_TEXT_PLUGIN_INSTALLED_SUGGEST_RESTART", "Alert informative text when a plugin was sucessfully installed");
    [alert addButtonWithTitle:NSLocalizedString(@"RESTART", @"Restart")];
    [alert addButtonWithTitle:NSLocalizedString(@"KEEP_RUNNING", @"Do not restart MacPass")];
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
      if(returnCode == NSAlertFirstButtonReturn) {
        [NSApp relaunchAfterDelay:3];
      }
    }];
  }
}

- (void)showRemovePluginAlert {
  MPPlugin *plugin = [self pluginForRow:self.pluginTableView.selectedRow];
  if(!plugin) {
    return;
  }
  NSAlert *alert = [[NSAlert alloc] init];
  alert.alertStyle = NSAlertStyleWarning;
  alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"ALERT_MESSAGE_TEXT_REALLY_UNINSTALL_PLUGIN_%@", "Alert message text to ask the user if he really want to uninstall the plugin. Include %@ placeholder for plugin name"), plugin.name];
  alert.informativeText = NSLocalizedString(@"ALERT_INFORMATIVE_TEXT_REALLY_UNINSTALL_PLUGIN", "Alert informative text to ask the user if he really want to uninstall the plugin");
  [alert addButtonWithTitle:NSLocalizedString(@"UNINSTALL", @"Uninstall plugin")];
  [alert addButtonWithTitle:NSLocalizedString(@"KEEP_PLUGIN", @"Do not install the plugin")];
  [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
    if(returnCode == NSAlertFirstButtonReturn) {
      [self _removePlugin:plugin];
    }
  }];
}

- (void)_removePlugin:(MPPlugin *)plugin {
  NSError *error;
  if(![[MPPluginHost sharedHost] uninstallPlugin:plugin error:&error]) {
    [NSApp presentError:error modalForWindow:self.view.window delegate:nil didPresentSelector:NULL contextInfo:NULL];
  }
  else {
    NSAlert *alert = [[NSAlert alloc] init];
    alert.alertStyle = NSAlertStyleInformational;
    alert.messageText = [NSString stringWithFormat:NSLocalizedString(@"ALERT_MESSAGE_TEXT_PLUGIN_%@_UNINSTALLED_SUGGEST_RESTART", "Alert message text when a plugin was successfully uninstalled. Include %@ placeholder for plugin name"), plugin.name];
    alert.informativeText = NSLocalizedString(@"ALERT_INFORMATIVE_TEXT_PLUGIN_UNINSTALLED_SUGGEST_RESTART", "Alert informative text when a plugin was sucessfully uninstalled");
    [alert addButtonWithTitle:NSLocalizedString(@"RESTART", @"Restart")];
    [alert addButtonWithTitle:NSLocalizedString(@"KEEP_RUNNING", @"Do not restart MacPass")];
    [alert beginSheetModalForWindow:self.view.window completionHandler:^(NSModalResponse returnCode) {
      if(returnCode == NSAlertFirstButtonReturn) {
        [NSApp relaunchAfterDelay:3];
      }
    }];
  }
}

@end
