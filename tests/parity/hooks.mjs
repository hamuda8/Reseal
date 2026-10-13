// Module resolution hook (see register.mjs): Reseal-js's test/harness.js becomes ours.
const ours = new URL('./harness.mjs', import.meta.url).href;

export async function resolve(specifier, context, next) {
  const parent = context.parentURL || '';
  if (/\/test\/[^/]+\.test\.js$/.test(parent) && (specifier === './harness.js' || specifier.endsWith('/test/harness.js'))) {
    return { url: ours, shortCircuit: true };
  }
  return next(specifier, context);
}
