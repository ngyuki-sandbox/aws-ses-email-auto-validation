export async function handler(event) {
    console.log(JSON.stringify(event));
    for (const rec of event.Records) {
        const message = JSON.parse(rec.Sns.Message);
        const content = message.content;
        const m = content.match(/^https:\/\/email-verification\.[-a-z0-9]+\.amazonaws\.com\/\S+$/m);
        if (m) {
            await fetch(m[0]);
        }
    }
}
