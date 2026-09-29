// Lock-free 64-bit loads and stores for the equalizer's parameters, shared between the main thread (writer) and the
// audio render thread (reader). Swift on iOS 17 has no atomics of its own without a package.
#ifndef EQAtomic_h
#define EQAtomic_h

static inline void ec_atomic_store_double(double *p, double v) {
    __atomic_store(p, &v, __ATOMIC_RELEASE);
}

static inline double ec_atomic_load_double(const double *p) {
    double v;
    __atomic_load(p, &v, __ATOMIC_ACQUIRE);
    return v;
}

#endif
