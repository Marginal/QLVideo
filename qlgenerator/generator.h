//
//  generator.h
//  QLVideo
//
//  Created by Jonathan Harris on 02/07/2016.
//
//

#ifndef generator_h
#define generator_h

// Constants defined in main.c

// Settings
extern NSString * const kSettingsSuiteName;
extern NSString * const kSettingsSnapshotCount;
extern NSString * const kSettingsSnapshotTime;
extern NSString * const kSettingsSnapshotAlways;

// Setting defaults
extern const int kDefaultSnapshotTime;
extern const int kDefaultSnapshotCount;

// Implementation
extern const int kMinimumDuration;
extern const int kMinimumPeriod;

// Globals
extern BOOL brokenQLCoverFlow;  // Whether we're on Mavericks which doesn't handle CoverFlow previews properly
extern BOOL hackedQLDisplay;    // Whether the user has symlinked QTKit-based LegacyMovie.qldisplay as Movie.qldisplay

#endif /* generator_h */
