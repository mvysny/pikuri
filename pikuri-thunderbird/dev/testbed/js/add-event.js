// Adds an event to the demo calendar while Thunderbird runs: the calendar
// change pikuri must see live (it lands in cache.sqlite's WAL first).
//   dev/thunderbird-testbed/session js dev/thunderbird-testbed/js/add-event.js
// Edit the id, title and times for another event. It stays in the demo
// calendar until the next build restores it.
const resolve = arguments[arguments.length - 1];
(async () => {
  const { cal } = ChromeUtils.importESModule("resource:///modules/calendar/calUtils.sys.mjs");
  const { CalEvent } = ChromeUtils.importESModule("resource:///modules/CalEvent.sys.mjs");
  const calendar = cal.manager.getCalendarById("pikuridemo");
  const event = new CalEvent();
  event.id = "live-event@novak.example";
  event.title = "Live event";
  event.startDate = cal.createDateTime("20261120T120000Z");
  event.endDate = cal.createDateTime("20261120T130000Z");
  await calendar.addItem(event);
  return event.id;
})().then(resolve, (e) => resolve({ error: String(e) }));
