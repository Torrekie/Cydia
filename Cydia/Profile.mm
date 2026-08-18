#include "Cydia/Profile.hpp"

struct timeval _ltv;
bool _itv;

std::vector<ProfileTime *> times_;

void PrintTimes() {
    for (std::vector<ProfileTime *>::const_iterator i(times_.begin()); i != times_.end(); ++i)
        (*i)->Print();
    std::cerr << "========" << std::endl;
}
