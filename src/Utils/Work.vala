/*
 * SPDX-License-Identifier: GPL-3.0-or-later
 * SPDX-FileCopyrightText: 2026 ByteTube Developers
 *
 * Off-main-thread helper.
 *
 * Decoding an image, reading a file or parsing a large response are all work
 * that would otherwise stall the window. This runs them on a small pool of
 * worker threads and resumes the calling coroutine on the main loop.
 *
 * Widgets may only be touched after the coroutine resumes — never inside the
 * job. The job runs on a thread that knows nothing about GTK.
 *
 * The pattern follows the one used in the sibling OpenCode client, which
 * solved the same problem.
 */

namespace ByteTube {

public delegate void WorkJob ();

/** A closure, boxed so it can be handed to a thread pool. */
private class WorkItem : GLib.Object {
    private WorkJob task;

    public WorkItem (owned WorkJob task) {
        this.task = (owned) task;
    }

    public void run () {
        task ();
    }
}

/** Carries a coroutine's continuation across a thread boundary.
 *
 *  Vala cannot copy a delegate, so the continuation is held by an object and
 *  only read back on the main loop. */
private class Resume : GLib.Object {
    private SourceFunc? continuation;

    public Resume (owned SourceFunc continuation) {
        this.continuation = (owned) continuation;
    }

    public void wake () {
        Idle.add (on_idle);
    }

    private bool on_idle () {
        var continuation = this.continuation;
        this.continuation = null;

        if (continuation != null) {
            continuation ();
        }

        return Source.REMOVE;
    }
}

public class Work : GLib.Object {
    private static GLib.ThreadPool<WorkItem>? pool = null;

    /** Runs `job` on a worker thread. Falls back to the calling thread when
     *  no worker can be had, so the work still happens. */
    public static void submit (owned WorkJob job) {
        if (pool == null) {
            try {
                pool = new GLib.ThreadPool<WorkItem>.with_owned_data ((item) => {
                    item.run ();
                }, 2, false);
            } catch (ThreadError e) {
                warning ("No worker pool, running inline: %s", e.message);
                job ();
                return;
            }
        }

        try {
            pool.add (new WorkItem ((owned) job));
        } catch (ThreadError e) {
            warning ("Worker pool refused the job, running inline: %s", e.message);
            job ();
        }
    }

    /**
     * Runs `job` on a worker thread and resumes the caller afterwards.
     *
     * Call it with `yield`, which is what supplies the continuation:
     *
     *     yield Work.submit_with_resume (() => { … });
     */
    public static void submit_with_resume (owned WorkJob job, owned SourceFunc continuation) {
        var resume = new Resume ((owned) continuation);

        submit (() => {
            job ();
            resume.wake ();
        });
    }
}
}
