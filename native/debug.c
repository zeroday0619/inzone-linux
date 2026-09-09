#include "header.h"

int inzone_dsp_debug_open(const char *path)
{
	int file = open(path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0600);
	struct stat status;

	if (file < 0)
		return -1;
	if (fstat(file, &status) != 0 || !S_ISREG(status.st_mode) ||
	    status.st_uid != geteuid() || fchmod(file, 0600) != 0) {
		close(file);
		return -1;
	}
	return file;
}
