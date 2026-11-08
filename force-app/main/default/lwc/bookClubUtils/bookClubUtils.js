// Turns wire/imperative Apex errors into a single readable message.
export function reduceErrors(error) {
    const errors = Array.isArray(error) ? error : [error];
    return errors
        .filter(Boolean)
        .map((e) => {
            if (Array.isArray(e.body)) {
                return e.body.map((b) => b.message).join(', ');
            }
            return e.body?.message ?? e.message ?? 'Unknown error';
        })
        .join(', ');
}

// October 31 in the viewer's time zone.
export function isHalloween(date = new Date()) {
    return date.getMonth() === 9 && date.getDate() === 31;
}
