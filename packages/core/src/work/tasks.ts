import type { UserId } from '../ids';
import type { DateKey } from '../time/time';

/** Work Center task model and pure view-model helpers. */

export type TaskStatus = 'todo' | 'in_progress' | 'blocked' | 'done';
export type TaskPriority = 'low' | 'normal' | 'high' | 'urgent';
export type TaskBucket = 'overdue' | 'today' | 'upcoming' | 'someday' | 'done';

export interface Task {
  readonly id: string;
  readonly title: string;
  readonly status: TaskStatus;
  readonly priority: TaskPriority;
  readonly assigneeId: UserId;
  readonly createdById: UserId;
  readonly due?: DateKey;
  /** Linked business record, e.g. `{ kind: 'timeoff', id }`. */
  readonly link?: { readonly kind: string; readonly id: string; readonly label: string };
}

const PRIORITY_WEIGHT: Readonly<Record<TaskPriority, number>> = { urgent: 0, high: 1, normal: 2, low: 3 };

export function bucketOf(task: Task, today: DateKey): TaskBucket {
  if (task.status === 'done') return 'done';
  if (task.due === undefined) return 'someday';
  if (task.due < today) return 'overdue';
  if (task.due === today) return 'today';
  return 'upcoming';
}

export const BUCKET_ORDER: readonly TaskBucket[] = ['overdue', 'today', 'upcoming', 'someday', 'done'];

/** Stable sort: priority, then due date, then title. */
export function compareTasks(a: Task, b: Task): number {
  return (
    PRIORITY_WEIGHT[a.priority] - PRIORITY_WEIGHT[b.priority] ||
    (a.due ?? '9999-12-31').localeCompare(b.due ?? '9999-12-31') ||
    a.title.localeCompare(b.title)
  );
}

/** Group tasks into ordered, sorted buckets; empty buckets are omitted. */
export function groupTasks(tasks: readonly Task[], today: DateKey): { bucket: TaskBucket; tasks: Task[] }[] {
  const groups = new Map<TaskBucket, Task[]>();
  for (const t of tasks) {
    const b = bucketOf(t, today);
    const list = groups.get(b);
    if (list === undefined) groups.set(b, [t]);
    else list.push(t);
  }
  return BUCKET_ORDER.flatMap((bucket) => {
    const list = groups.get(bucket);
    return list === undefined ? [] : [{ bucket, tasks: [...list].sort(compareTasks) }];
  });
}
