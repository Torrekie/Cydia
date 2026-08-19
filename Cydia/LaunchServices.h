/* Cydia - iPhone UIKit Front-End for Debian APT
 * Copyright (C) 2008-2015  Jay Freeman (saurik)
 */

#ifndef CYDIA_LAUNCH_SERVICES_H
#define CYDIA_LAUNCH_SERVICES_H

#if __has_include(<launch.h>)
#include <launch.h>
#else

#include <cstddef>

#define LAUNCH_KEY_GETJOB "GetJob"
#define LAUNCH_KEY_GETJOBS "GetJobs"

#define LAUNCH_JOBKEY_ENVIRONMENTVARIABLES "EnvironmentVariables"
#define LAUNCH_JOBKEY_PID "PID"
#define LAUNCH_JOBKEY_PROGRAM "Program"
#define LAUNCH_JOBKEY_PROGRAMARGUMENTS "ProgramArguments"

typedef struct _launch_data *launch_data_t;
typedef void (*launch_data_dict_iterator_t)(launch_data_t value,
                                             const char *key,
                                             void *context);

typedef enum {
    LAUNCH_DATA_DICTIONARY = 1,
    LAUNCH_DATA_ARRAY,
    LAUNCH_DATA_FD,
    LAUNCH_DATA_INTEGER,
    LAUNCH_DATA_REAL,
    LAUNCH_DATA_BOOL,
    LAUNCH_DATA_STRING,
    LAUNCH_DATA_OPAQUE,
    LAUNCH_DATA_ERRNO,
    LAUNCH_DATA_MACHPORT,
} launch_data_type_t;

#ifdef __cplusplus
extern "C" {
#endif

launch_data_t launch_data_alloc(launch_data_type_t type);
launch_data_type_t launch_data_get_type(const launch_data_t data);
void launch_data_free(launch_data_t data);
bool launch_data_dict_insert(launch_data_t dictionary,
                             const launch_data_t value,
                             const char *key);
launch_data_t launch_data_dict_lookup(const launch_data_t dictionary,
                                      const char *key);
void launch_data_dict_iterate(const launch_data_t dictionary,
                              launch_data_dict_iterator_t iterator,
                              void *context);
launch_data_t launch_data_array_get_index(const launch_data_t array,
                                          std::size_t index);
std::size_t launch_data_array_get_count(const launch_data_t array);
launch_data_t launch_data_new_string(const char *value);
long long launch_data_get_integer(const launch_data_t data);
const char *launch_data_get_string(const launch_data_t data);
launch_data_t launch_msg(const launch_data_t request);

#ifdef __cplusplus
}
#endif

#endif /* __has_include(<launch.h>) */

#endif
