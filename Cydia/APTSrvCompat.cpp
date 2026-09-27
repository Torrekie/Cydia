#include <apt-pkg/srvrec.h>

#include <string>
#include <vector>

/* iOS does not expose the resolver-private SRV helpers used by APT's desktop
 * implementation.  SRV lookup is an optional connection optimization; the
 * normal address resolution path remains in the embedded method backend. */
bool GetSrvRecords(std::string, std::vector<SrvRec> &result)
{
    result.clear();
    return false;
}

bool GetSrvRecords(std::string, int, std::vector<SrvRec> &result)
{
    result.clear();
    return false;
}

SrvRec PopFromSrvRecs(std::vector<SrvRec> &records)
{
    if (records.empty())
        return SrvRec("", 0, 0, 0);
    SrvRec value(records.back());
    records.pop_back();
    return value;
}
