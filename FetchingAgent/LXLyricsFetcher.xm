#import "LXLyricsFetcher.h"

@interface SBLockScreenManager: NSObject {
    BOOL _isScreenOn;
}
    + (id) sharedInstanceIfExists;
@end

@interface LastLookManager: NSObject
    - (BOOL) isActive;

    + (instancetype) sharedInstance;
@end

@interface AVRoutingSessionManager: NSObject
    @property (atomic, assign, readonly) id currentRoutingSession;

    + (AVRoutingSessionManager*) longFormVideoRoutingSessionManager; // doesn't return the same AVRoutingSessionManager instance as the SB original one, it probably returns a new one for video, but the original one doesn't have a sharedInstance, and both have same destination, so I'm using this one!
@end

@interface SBApplication: NSObject 
    @property (nonatomic, readonly) NSString* bundleIdentifier;
@end

@interface SBMediaController: NSObject
    @property (nonatomic, readonly) SBApplication* nowPlayingApplication;

    - (instancetype) sharedInstance;
@end

BOOL isPlayingFromSpotify() {
    NSString *nowPlayingBundleId = [[[%c(SBMediaController) sharedInstance] nowPlayingApplication] bundleIdentifier];
    return [nowPlayingBundleId isEqualToString: @"com.spotify.client"];
}

BOOL isAirPlaying() {
    return [%c(AVRoutingSessionManager) longFormVideoRoutingSessionManager].currentRoutingSession != nil;
}

@implementation LXLyricsFetcher
    @synthesize lyrics;
    @synthesize lastSong;
    @synthesize playbackProgress;
    @synthesize lyricsTimer;

    // Store one instance of the main class
    static LXLyricsFetcher *LXLyricsFetcherInstance;

    - (void) start {
        [self fire];
        self.lyricsTimer = [NSTimer scheduledTimerWithTimeInterval: 0.2
                 target: self
                 selector: @selector(fire)
                 userInfo: nil
                 repeats: true];
    }

    - (void) fire {
        LastLookManager *lastLookManager = [%c(LastLookManager) sharedInstance];
        SBLockScreenManager *manager = [%c(SBLockScreenManager) sharedInstanceIfExists];
        
        if ((!lastLookManager || (lastLookManager && ![lastLookManager isActive])) && manager) {
            BOOL isScreenOn = MSHookIvar<BOOL>(manager, "_isScreenOn");
            if (!isScreenOn) {
                return;
            }
        }

        [self fetchCurrentPlayback];

        if (!lyrics || !playbackProgress) {
            return;
        }

        [self updateLyricsForProgress: playbackProgress];
    }

    - (void) fetchCurrentPlayback {
        MRMediaRemoteGetNowPlayingInfo(dispatch_get_main_queue(), ^(CFDictionaryRef information) {
			NSDictionary *info = (__bridge NSDictionary*) information;

            CFAbsoluteTime absoluteTime = CFAbsoluteTimeGetCurrent();
            CFAbsoluteTime timestamp = CFDateGetAbsoluteTime((CFDateRef)[info objectForKey:@"kMRMediaRemoteNowPlayingInfoTimestamp"]);
            double timeIntervalifPause = [[info objectForKey:@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
            NSTimeInterval timeInterval = (absoluteTime - timestamp) + timeIntervalifPause;
            if (isnan(timeInterval)) {
                timeInterval = 0;
            }
            // Set current playback progress (e.g. 204.34 seconds)
            self.playbackProgress = timeInterval;

            if (isAirPlaying() && isPlayingFromSpotify() && self.playbackProgress > 1.5) {
                self.playbackProgress -= 1.5;
            }

            NSNumber *_rate = (NSNumber*) info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"];
			double rate = [_rate doubleValue];
			double playingRate = 1;
			BOOL isPlaying = rate == playingRate;
			NSString *infoTitle = (NSString *) info[@"kMRMediaRemoteNowPlayingInfoTitle"];
			if (infoTitle == NULL || !isPlaying) {
                self.lyrics = NULL;
                self.lastSong = @"";
                [self broadcastText: @"Paused"];
				return;
			}
			NSString *infoArtist = (NSString *) info[@"kMRMediaRemoteNowPlayingInfoArtist"];
			NSString *queryString = [NSString stringWithFormat: @"%@%@%@",  infoTitle, @" ", infoArtist];

            if ([queryString isEqual: lastSong]) {
                return;
            }

            self.lastSong = queryString;

            [self fetchLyricsForSong: infoTitle byArtist: infoArtist];
        });
    }

    // Parses an LRC-formatted synced lyrics string (e.g. "[00:12.34]Some line\n[00:15.67]Next line")
    // into an array of @{ @"lyrics": NSString*, @"seconds": NSNumber* } dictionaries,
    // which is the format the rest of this class (updateLyricsForProgress:) expects.
    - (NSArray*) parseSyncedLyrics:(NSString*)syncedLyrics {
        NSMutableArray *items = [NSMutableArray array];

        NSError *regexError;
        NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern: @"^\\[(\\d{2}):(\\d{2})\\.(\\d{2,3})\\](.*)$"
                                                                                options: NSRegularExpressionAnchorsMatchLines
                                                                                  error: &regexError];
        if (regexError != nil) {
            return items;
        }

        NSArray<NSString*> *lines = [syncedLyrics componentsSeparatedByString: @"\n"];

        for (NSString *rawLine in lines) {
            NSTextCheckingResult *match = [regex firstMatchInString: rawLine
                                                             options: 0
                                                               range: NSMakeRange(0, [rawLine length])];
            if (match == nil || [match numberOfRanges] < 5) {
                continue;
            }

            NSInteger minutes = [[rawLine substringWithRange: [match rangeAtIndex: 1]] integerValue];
            NSInteger seconds = [[rawLine substringWithRange: [match rangeAtIndex: 2]] integerValue];
            NSString *fractionStr = [rawLine substringWithRange: [match rangeAtIndex: 3]];
            double fraction = [fractionStr doubleValue] / pow(10, [fractionStr length]);
            NSString *text = [rawLine substringWithRange: [match rangeAtIndex: 4]];

            double totalSeconds = (minutes * 60) + seconds + fraction;

            NSDictionary *newDict = @{ @"lyrics": text, @"seconds": [NSNumber numberWithDouble: totalSeconds] };
            [items addObject: newDict];
        }

        return items;
    }

    - (void) fetchLyricsForSong:(NSString*)song byArtist:(NSString*)artist {
        self.lyrics = NULL;
        [self broadcastText: @"Loading..."];

        dispatch_queue_t queue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0ul);
	    dispatch_async(queue, ^{
		    NSURLSessionConfiguration *defaultSessionConfiguration = [NSURLSessionConfiguration defaultSessionConfiguration];
    	    NSURLSession *defaultSession = [NSURLSession sessionWithConfiguration:defaultSessionConfiguration];
		    NSString *escapedSong = [song stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
            NSString *escapedArtist = [artist stringByAddingPercentEncodingWithAllowedCharacters:[NSCharacterSet URLQueryAllowedCharacterSet]];
		    // Previously used https://prv.textyl.co, which has been discontinued (502 / expired cert).
		    // Switched to LRCLIB (https://lrclib.net), a free, actively maintained, keyless synced-lyrics API.
		    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat: @"https://lrclib.net/api/get?track_name=%@&artist_name=%@", escapedSong, escapedArtist]];
		    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL: url];
		    // LRCLIB asks clients to identify themselves with a descriptive User-Agent.
		    [request setValue: @"Lyrication (jailbreak tweak; +https://github.com/thatmarcel/lyrication)" forHTTPHeaderField: @"User-Agent"];
		    NSURLSessionDataTask *dataTask = [defaultSession dataTaskWithRequest: request completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
			    dispatch_async(dispatch_get_main_queue(), ^{
				    if (![[self lastSong] isEqual: [NSString stringWithFormat: @"%@%@%@",  song, @" ", artist]]) {
					    return;
				    }

				    NSInteger statusCode = 0;

				    if ([response isKindOfClass:[NSHTTPURLResponse class]]) {
    				    NSHTTPURLResponse *httpResponse = (NSHTTPURLResponse *)response;
    				    statusCode = httpResponse.statusCode;
				    }

				    if (statusCode != 200 || data == nil) {
					    [self showNoLyricsAvailable];
					    return;
				    }

				    NSError* errorr;
				    NSDictionary* json = (NSDictionary*) [NSJSONSerialization JSONObjectWithData:data options:kNilOptions error:&errorr];
				    if (errorr != nil || ![json isKindOfClass:[NSDictionary class]]) {
					    [self showNoLyricsAvailable];
					    return;
				    }

				    NSString *syncedLyrics = [json objectForKey: @"syncedLyrics"];
				    if (syncedLyrics == nil || [syncedLyrics isEqual: [NSNull null]] || [syncedLyrics length] < 1) {
					    [self showNoLyricsAvailable];
					    return;
				    }

				    NSArray *items = [self parseSyncedLyrics: syncedLyrics];
				    if ([items count] < 1) {
					    [self showNoLyricsAvailable];
					    return;
				    }

	                [self setLyrics:items];
			    });
    	    }];
		    [dataTask resume];
	    });
    }

    - (void) updateLyricsForProgress:(double)progress {
        double smallestdistance = 999999;
		int smallestdistanceindex = 0;

		int index = 0;

		for (NSDictionary *dict in [self lyrics]) {
			double seconds = [[dict objectForKey:@"seconds"] doubleValue];

			double itemsmallestdistance = seconds - progress;

			if (itemsmallestdistance < 0) {
				itemsmallestdistance = -itemsmallestdistance;
			} else {
                continue;
            }

			if (smallestdistance < itemsmallestdistance) {
				continue;
			}

			smallestdistanceindex = index;
			smallestdistance = itemsmallestdistance;

			index += 1;
		}

        NSDictionary *item = [self lyrics][smallestdistanceindex];
		NSString *line = [item objectForKey:@"lyrics"];

        [self broadcastText: line];
    }

    - (void) showNoLyricsAvailable {
        [self broadcastText: @"No lyrics available"];
    }

    - (void) broadcastText:(NSString*)text {
        NSMutableDictionary *userInfo = [NSMutableDictionary new];
        [userInfo setObject: text forKey: @"line"];
        [[NSDistributedNotificationCenter defaultCenter]
            postNotificationName: @"com.thatmarcel.tweaks.lyrication/updateLine"
            object: nil
            userInfo: userInfo
        ];
    }

@end

%ctor {
    LXLyricsFetcherInstance = [[LXLyricsFetcher alloc] init];
    [LXLyricsFetcherInstance start];
}
