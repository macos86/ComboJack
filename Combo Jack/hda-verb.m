/*
 * Accessing HD-audio verbs via hwdep interface
 * Version 0.3
 *
 * Copyright (c) 2008 Takashi Iwai <tiwai@suse.de>
 *
 * Licensed under GPL v2 or later.
 */

//
// Based on alc-verb from AppleALC
//
// Conceptually derived from ALCPlugFix:
// https://github.com/goodwin/ALCPlugFix
//
// values come from https://github.com/torvalds/linux/blob/master/sound/pci/hda/patch_realtek.c

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>
#include <unistd.h>
#include <stdint.h>
#include <pthread.h>
#include <IOKit/IOKitLib.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_port.h>
#include <mach/mach_interface.h>
#include <mach/mach_init.h>
#include <sys/stat.h>
#include <semaphore.h>
#include <IOKit/IOMessage.h>
#include <IOKit/pwr_mgt/IOPMLib.h>
#include <inttypes.h>

#include "PCI.h"

// For driver
#include "hda-verb.h"

#define GET_CFSTR_FROM_DICT(_dict, _key) (__bridge CFStringRef)[_dict objectForKey:_key]

//
// Global Variables
//
CFURLRef iconUrl = NULL;
io_service_t AppleAlcUserClientIOService;
io_connect_t DataConnection;
uint32_t connectiontype = 0;
uint8_t previousState = 0;
bool run = true;
bool awake = false;
bool isSleeping = false;
bool restorePreviousState = false;
io_connect_t  root_port;
io_object_t   notifierObject;
struct stat consoleinfo;

long codecID = 0;

//dialog text
NSDictionary *dlgText;

//
// Open connection to IOService
//

uint32_t OpenServiceConnection(void)
{
    //
    // Having a kernel-side server (AppleAlc) and a user-side client (alc-verb) is really the only way to ensure that hda-
    // verb won't break when IOAudioFamily changes. This 2-component solution is necessary because we can't compile kernel
    // libraries into user-space programs on macOS and expect them to work generically.
    //
    // Additionally, if this program were made as a single executable that accessed device memory regions directly, it would
    // only be guaranteed to work for one machine on one BIOS version since memory regions change depending on hardware
    // configurations. This is why Raspberry Pis, STM32s, and other embedded platforms are nice to program on: They don't
    // change much between versions so programs can be made extremely lightweight. Linux also does a pretty good job
    // achieving a similar situation, since everything (devices, buses, etc.) on Linux is represented by an easily
    // accessible file (just look at how simple the hda-verb program in alsa-tools is! All it uses is ioctl).
    //
    
    CFMutableDictionaryRef appleAlcDict = IOServiceMatching(kALCUserClientProvider);
    
    // Use IOServiceGetMatchingService since we can reasonably expect "AppleAlc" is the only IORegistryEntry of its kind.
    // Otherwise IOServiceGetMatchingServices with an iterating algorithm must be used to find the kernel extension.
    
    AppleAlcUserClientIOService = IOServiceGetMatchingService(kIOMasterPortDefault, appleAlcDict);
    
    // Hopefully the kernel extension loaded properly so it can be found.
    if (!AppleAlcUserClientIOService)
    {
        fprintf(stderr, "Could not locate AppleAlc kext. Ensure it is loaded and alcverbs=1 in bootargs; verbs cannot be sent otherwise.\n");
        return -1;
    }
    
    // Connect to the IOService object
    // Note: kern_return_t is just an int
    kern_return_t kernel_return_status = IOServiceOpen(AppleAlcUserClientIOService, mach_task_self(), connectiontype, &DataConnection);
    
    if (kernel_return_status != kIOReturnSuccess)
    {
        fprintf(stderr, "Failed to open AppleALC IOService: %08x.\n", kernel_return_status);
        return -1;
    }
    
    return kernel_return_status; // 0 if successful
}

int indexOf(int *array, int array_size, int number) {
    for (int i = 0; i < array_size; ++i) {
        if (array[i] == number) {
            return i;
        }
    }
    return -1;
}

int indexOf_L(long *array, int array_size, long number) {
    for (int i = 0; i < array_size; ++i) {
        if (array[i] == number) {
            return i;
        }
    }
    return -1;
}

//
// Send verb command
//

static uint32_t AlcVerbCommand(uint16_t nid, uint16_t verb,uint16_t param)
{
    //
    // Call the function ultimately responsible for sending commands in the kernel extension. That function will return the
    // response we also want.
    // https://lists.apple.com/archives/darwin-drivers/2008/Mar/msg00007.html
    //
    
    uint32_t inputCount = 3; // Number of input arguments
    uint32_t outputCount = 1; // Number of elements in output
    uint64_t input[inputCount]; // Array of input scalars
    uint64_t output; // Array of output scalars
    
    input[0] = nid;
    
    if (verb & 0xff){
        input[1] = verb;
    } else {
        input[1] = verb >> 8;
    }
    
    input[2] = param;
    
    // IOConnectCallScalarMethod was introduced in Mac OS X 10.5
    
    kern_return_t kernel_return_status = IOConnectCallScalarMethod(DataConnection, connectiontype, input, inputCount, &output, &outputCount);
    
    if (kernel_return_status != kIOReturnSuccess)
    {
        fprintf(stderr, "Error sending command.\n");
        return -1;
    }
    
    // Return command response
    return (uint32_t)output;
}


static uint32_t GetJackStatus(void)
{

    return AlcVerbCommand(0x21, AC_VERB_GET_PIN_SENSE, 0x00);
}

//
// Close connection to IOService
//

void CloseServiceConnection(void)
{
    // Done with the VerbStub IOService object, so we don't need to hold on to it anymore
    IOObjectRelease(AppleAlcUserClientIOService);
    IODeregisterForSystemPower(&notifierObject);
}

//
// Unplugged Settings
//

static uint32_t unplugged(void)
{
    if (!restorePreviousState) {
        fprintf(stderr, "Jack Status: unplugged.\n");
        previousState = 0;
    
        switch (codecID)
        {
            case 0x10ec0236:
                AlcVerbCommand(0x12, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x20);
                AlcVerbCommand(0x14, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x40);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x02);
                AlcVerbCommand(0x21, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x00);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD089);
                break;
            case 0x10ec0255:
                AlcVerbCommand(0x12, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x20);
                AlcVerbCommand(0x14, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x40);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x02);
                AlcVerbCommand(0x21, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x00);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD089);
                break;
            case 0x10ec0256:
                AlcVerbCommand(0x12, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x20);
                AlcVerbCommand(0x14, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x40);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x02);
                AlcVerbCommand(0x21, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x00);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD089);
                break;
            case 0x10ec0289:
                AlcVerbCommand(0x12, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x20);
                AlcVerbCommand(0x14, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x40);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x02);
                AlcVerbCommand(0x21, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x00);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD289);
                break;
            case 0x10ec0295:
                AlcVerbCommand(0x12, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x20);
                AlcVerbCommand(0x14, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x40);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x02);
                AlcVerbCommand(0x21, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x00);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD289);
                break;
            default:
                break;
        }
    }
        
    return 0; // Success
}

//
// Headphones Settings
//

static uint32_t headphones(void)
{
    if (!restorePreviousState) {
        fprintf(stderr, "Jack Status: headphones plugged in.\n");
        previousState = 1;
    
        switch (codecID)
        {
            case 0x10ec0236:
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xC489);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                break;
            case 0x10ec0255:
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xC489);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                break;
            case 0x10ec0256:
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xC489);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                break;
            case 0x10ec0289:
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xC689);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                break;
            case 0x10ec0295:
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xC689);
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                break;
            default:
                break;
        }
    }
        
    return 0; // Success
}

//
// Headset Auto-Detection
//

static uint32_t headset(void)
{
    if (!restorePreviousState) {
        fprintf(stderr, "Jack Status: headset plugged in.\n");
        previousState = 2;
    
        switch (codecID)
        {
            case 0x10ec0236:
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD689);
                usleep(350000);
                break;
            case 0x10ec0255:
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD689);
                usleep(350000);
                break;
            case 0x10ec0256:
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD689);
                usleep(350000);
                break;
            case 0x10ec0289:
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD689);
                usleep(350000);
                break;
            case 0x10ec0295:
                AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
                AlcVerbCommand(0x20, AC_VERB_SET_COEF_INDEX,         0x45);
                AlcVerbCommand(0x20, AC_VERB_SET_PROC_COEF,          0xD689);
                usleep(350000);
                break;
            default:
                break;
        }
    }
        
    return 0; // Success
}

//
// Jack unplug monitor
//

void JackBehavior(void)
{
    int counter = 4;
    
    while (run) // Poll headphone jack state
    {
        usleep(250000); // Polling frequency (seconds): use usleep for microseconds if finer-grained control is needed
        
        if (awake)
        {
            awake = false;
            break;
        }
        
        if ((GetJackStatus() & 0x80000000) != 0x80000000)
        {
            if (--counter < 0)
                break;
        }
        else
            counter = 4;
    }
    
    if (run) // If process is killed, maintain current state
    {
        if (!isSleeping) {
            fprintf(stderr, "JackBehavior Unplugged.\n");
            unplugged(); // Clean up, jack's been unplugged or process was killed
        }
        
    }
}

//
// Pop-up menu
//

uint32_t CFPopUpMenu(void)
{
    CFOptionFlags responsecode;
    responsecode = 0;
    fprintf(stderr, "Response code before value: %lu.\n", responsecode);
    while(true)
    {
        //wait until user logged in
        stat("/dev/console", &consoleinfo);
        if (!consoleinfo.st_uid)
        {
            sleep(1);
            continue;
        }
        else if ((GetJackStatus() & 0x80000000) != 0x80000000){
            fprintf(stderr, " CFPopUpMenu unplugged!\n");
            if (!isSleeping) {
                return unplugged();
            }
        }
            
        if (awake) awake = false;
        //get current locale settings
        //NSString *locale = [[NSUserDefaults standardUserDefaults] stringForKey:@"AppleLocale"];
        //load localized strings
        if (restorePreviousState) {
            usleep(20000);
            restorePreviousState = false;
            switch (previousState) {
                case 0:
                    return unplugged();
                    break;
                case 1:
                    return headphones();
                    break;
                case 2:
                    return headset();
                    break;
                default:
                    break;
            }
        }
        NSMutableDictionary* Merged = dlgText.mutableCopy;
        //display dialog
        CFUserNotificationDisplayAlert(
                0, // CFTimeInterval timeout
                kCFUserNotificationNoteAlertLevel, // CFOptionFlags flags
                iconUrl, // CFURLRef iconURL (file location URL)
                NULL, // CFURLRef soundURL (unused)
                NULL, // CFURLRef localizationURL
                GET_CFSTR_FROM_DICT(Merged, @"dialogTitle"), //CFStringRef alertHeader
                GET_CFSTR_FROM_DICT(Merged, @"dialogMsg"), //CFStringRef alertMessage
                GET_CFSTR_FROM_DICT(Merged, @"btnHeadphone"), //CFStringRef defaultButtonTitle
                GET_CFSTR_FROM_DICT(Merged, @"btnMicin"), //CFStringRef alternateButtonTitle
                //GET_CFSTR_FROM_DICT(Merged, @"btnCancel"), //CFStringRef alternateButtonTitle
                GET_CFSTR_FROM_DICT(Merged, @"btnHeadset"), //CFStringRef otherButtonTitle
                &responsecode // CFOptionFlags *responseFlags
        );
        break;
    }
    
    if ((GetJackStatus() & 0x80000000) != 0x80000000) {
        fprintf(stderr, "CFPopUpMenu unplugged!\n");
        if (!isSleeping) {
            return unplugged();
        }
    }
        
    
    /* Responses are of this format:
     kCFUserNotificationDefaultResponse     = 0,
     kCFUserNotificationAlternateResponse   = 1,
     kCFUserNotificationOtherResponse       = 2,
     kCFUserNotificationCancelResponse      = 3
     */

    fprintf(stderr, "Response code after: %lu.\n", responsecode);
    responsecode = (responsecode << 40) >> 40;
    fprintf(stderr, "Response code fixed: %lu.\n", responsecode);

    switch (responsecode)
    {
        case kCFUserNotificationDefaultResponse:
            fprintf(stderr, "Headphones selected.\n");
            return headphones();
            break;
        case kCFUserNotificationOtherResponse:
            fprintf(stderr, "Headset selected.\n");
            return headset();
            break;
        default:
            fprintf(stderr, "Cancelled.\n");
        //    return unplugged(); // This was originally meant to reset the jack state to "unplugged," but "maintaining current state" is more intuitive
            return 0; // Maintain current state
            break;
    }
    
    return 0;
}

//
// Respect OS signals
//

void sigHandler(int signo)
{
    fprintf(stderr, "\nsigHandler: Received signal %d\n", signo); // Technically this print is not async-safe, but so far haven't run into any issues
    switch (signo)
    {
        // Need to be sure object gets released correctly on any kind of quit
        // notification, otherwise the program's left still running!
        case SIGINT: // CTRL + c or Break key
        case SIGTERM: // Shutdown/Restart
        case SIGHUP: // "Hang up" (legacy)
        case SIGKILL: // Kill
        case SIGTSTP: // Close terminal from x button
            run = false;
            break; // SIGTERM, SIGINT mean we must quit, so do it gracefully
        default:
            break;
    }
}

//Codec fixup, invoked when boot/wake
void alcInit(void)
{
    fprintf(stderr, "Init codec.\n");
    switch (codecID)
    {
        case 0x10ec0236:
            AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
            AlcVerbCommand(0x21, AC_VERB_SET_UNSOLICITED_ENABLE, 0x83);
            break;
        case 0x10ec0255:
            AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
            AlcVerbCommand(0x21, AC_VERB_SET_UNSOLICITED_ENABLE, 0x83);
            break;
        case 0x10ec0256:
            AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
            AlcVerbCommand(0x21, AC_VERB_SET_UNSOLICITED_ENABLE, 0x83);
            break;
        case 0x10ec0289:
            AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
            AlcVerbCommand(0x21, AC_VERB_SET_UNSOLICITED_ENABLE, 0x83);
            break;
        case 0x10ec0295:
            AlcVerbCommand(0x19, AC_VERB_SET_PIN_WIDGET_CONTROL, 0x24);
            AlcVerbCommand(0x21, AC_VERB_SET_UNSOLICITED_ENABLE, 0x83);
            break;
        default:
            break;
    }
}

// Sleep/Wake event callback function, calls the fixup function
void SleepWakeCallBack( void * refCon, io_service_t service, natural_t messageType, void * messageArgument )
{
    switch ( messageType )
    {
        case kIOMessageCanSystemSleep:
            IOAllowPowerChange( root_port, (long)messageArgument );
            break;
        case kIOMessageSystemWillSleep:
            isSleeping = true;
            IOAllowPowerChange( root_port, (long)messageArgument );
            break;
        case kIOMessageSystemWillPowerOn:
            break;
        case kIOMessageSystemHasPoweredOn:
            //usleep(35000);
            restorePreviousState = true;
            if (isSleeping)
            {
                while(run)
                {
                    if (GetJackStatus() != -1){
                        break;
                    }
                    usleep(10000);
                }
                printf( "Re-init codec...\n" );
                alcInit();
                if ((GetJackStatus() & 0x80000000) == 0x80000000) {
                    usleep(10000);
                }
                
                awake = true;
                isSleeping = false;
            }
            
            break;
        default:
            break;
    }
}

// start cfrunloop that listen to wakeup event
void watcher(void)
{
    IONotificationPortRef  notifyPortRef;
    void*                  refCon = NULL;
    root_port = IORegisterForSystemPower( refCon, &notifyPortRef, SleepWakeCallBack, &notifierObject );
    if ( root_port == 0 )
    {
        printf("IORegisterForSystemPower failed\n");
        exit(1);
    }
    else
    {
        CFRunLoopAddSource( CFRunLoopGetCurrent(),
            IONotificationPortGetRunLoopSource(notifyPortRef), kCFRunLoopCommonModes );
            printf("Starting wakeup watcher\n");
            CFRunLoopRun();
    }
}


//Get onboard audio device info, adapted from DPCIManager
void getAudioID(void)
{
    (void)(codecID = 0);
    
    codecID   = AlcVerbCommand(0x00, AC_VERB_PARAMETERS, AC_PAR_VENDOR_ID);
    
    fprintf(stderr, "CodecID: 0x%lx\n", codecID);
    
}

//
// Main
//

int main(void)
{
    fprintf(stderr, "Starting jack watcher.\n");
    //Allow only one instance
    if (sem_open("ComboJack_Watcher", O_CREAT, 600, 1) == SEM_FAILED)
    {
        fprintf(stderr, "Another instance is already running!\n");
        return 1;
    }
    // Set up error handler
    signal(SIGHUP, sigHandler);
    signal(SIGTERM, sigHandler);
    signal(SIGINT, sigHandler);
    signal(SIGKILL, sigHandler);
    signal(SIGTSTP, sigHandler);
    
    // Local variables
    kern_return_t ServiceConnectionStatus;
    //int nid, verb, param;
    uint32_t jackstat;
    //struct hda_verb_ioctl val;

    // Establish user-kernel connection
    ServiceConnectionStatus = OpenServiceConnection();
    if (ServiceConnectionStatus != kIOReturnSuccess)
    {
        while ((ServiceConnectionStatus != kIOReturnSuccess) && run)
        {
            fprintf(stderr, "Error establshing IOService connection. Retrying in 1 second...\n");
            sleep (1);
            ServiceConnectionStatus = OpenServiceConnection();
        }
    }

    // Get audio device info, exit if no compatible device found
    getAudioID();

    //alc256 init
    alcInit();
    //start a new thread that waits for wakeup event
    pthread_t watcher_id;
    if (pthread_create(&watcher_id,NULL,(void*)watcher,NULL))
    {
        fprintf(stderr, "create pthread error!\n");
        return 1;
    }
    
    //load ui resources
    iconUrl = CFURLCreateWithString(NULL, CFSTR("file:///usr/local/share/ComboJack/Headphone.icns"), NULL);
    if (!CFURLResourceIsReachable(iconUrl, NULL))
        iconUrl = NULL;

    dlgText = [[NSDictionary alloc] initWithObjectsAndKeys:
        @"Combo Jack Notification", @"dialogTitle",
        @"What did you just plug in? (Press ESC to cancel)", @"dialogMsg",
        @"Headphones", @"btnHeadphone",
        @"Headset", @"btnHeadset",
        @"Cancel", @"btnCancel",
        nil];
    
    int counter = 4;
    
    while(run) // Poll headphone jack state
    {
        if (!isSleeping){
            jackstat = GetJackStatus();
            if (jackstat == -1) // 0xFFFFFFFF means jack not ready yet
            {
                fprintf(stderr, "Jack not ready. Checking again in 1 second...\n");
                counter = 4;
            }
            else if ((jackstat & 0x80000000) == 0x80000000)
            {
                if (--counter < 0)
                {
                    fprintf(stderr, "Jack sense detected! Displaying menu...\n");
                    counter = 4;
                    if (CFPopUpMenu() == 0)
                    {
                        JackBehavior();
                    }
                    else
                    {
                        break;
                    }
                }
            }
            else
                counter = 4;
        }
        
        //if (awake) awake = false;
        usleep(250000); // Sleep delay (seconds): use usleep for microseconds if fine-grained control is needed
    }

    sem_unlink("ComboJack_Watcher");
    // All done here, clean up and exit safely
    CloseServiceConnection();
    /*
    IODeregisterForSystemPower(&notifier);
    IOServiceClose(rootPort);
    IONotificationPortDestroy(notificationPort);
    */
    fprintf(stderr, "Exiting safely!\n");
    
    return 0;
}
