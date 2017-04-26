/* Copyright 2015 Marvin Beckers <beckersmarvin@gmail.com>
*
* This program is free software: you can redistribute it
* and/or modify it under the terms of the GNU General Public License as
* published by the Free Software Foundation, either version 3 of the
* License, or (at your option) any later version.
*
* This program is distributed in the hope that it will be
* useful, but WITHOUT ANY WARRANTY; without even the implied warranty of
* MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General
* Public License for more details.
*
* You should have received a copy of the GNU General Public License along
* with this program. If not, see http://www.gnu.org/licenses/.
*/

public class AppCenterCore.Client : Object {
    public signal void operation_finished (Package package, Package.State operation, Error? error);
    public signal void updates_available ();

    private const string RESTART_REQUIRED_FILE = "/var/run/reboot-required";

    public bool connected { public get; private set; }
    public bool updating_cache { public get; private set; }
    public bool restart_required { public get; private set; default = false; }
    private uint _task_count = 0;
    public uint task_count {
        public get {
            return _task_count;
        }
        private set {
            _task_count = value;
            last_action = new DateTime.now_local ();
        }
    }

    public AppCenterCore.Package os_updates { public get; private set; }

    private Gee.HashMap<string, AppCenterCore.Package> package_list;
    private AppStream.Pool appstream_pool;
    private Gee.TreeSet<AppStream.Component> drivers;
    private GLib.Cancellable cancellable;
    private GLib.DateTime last_cache_update;
    private GLib.DateTime last_action;
    private uint updates_number = 0U;
    private uint update_cache_timeout_id = 0;
    private bool refresh_in_progress = false;

    private const int SECONDS_BETWEEN_REFRESHES = 60*60*24;
    private const int PACKAGEKIT_ACTIVITY_TIMEOUT_MS = 2000;

    private Task client;
    private SuspendControl sc;

    private FileMonitor restart_monitor;

    private Client () {
    }

    construct {
        package_list = new Gee.HashMap<string, AppCenterCore.Package> (null, null);
        cancellable = new GLib.Cancellable ();

        client = new Task ();
        sc = new SuspendControl ();

        var restart_file = File.new_for_path (RESTART_REQUIRED_FILE);
        try {
            restart_monitor = restart_file.monitor (FileMonitorFlags.NONE);
            restart_monitor.changed.connect ((file) => update_restart_state (file));
        } catch (Error e) {
            warning (e.message);
        }

        update_restart_state (restart_file);

        cancellable = new GLib.Cancellable ();
        last_cache_update = null;

        appstream_pool = new AppStream.Pool ();
        // We don't want to show installed desktop files here
        appstream_pool.set_flags (appstream_pool.get_flags () & ~AppStream.PoolFlags.READ_DESKTOP_FILES);

        drivers = new Gee.TreeSet<AppStream.Component> ();
        try {
            appstream_pool.load ();
            appstream_pool.get_components ().foreach ((comp) => {
                var kind = comp.get_kind ();
                if (kind == AppStream.ComponentKind.DRIVER || kind == AppStream.ComponentKind.FIRMWARE) {
                    drivers.add (comp);
                    return;
                }

                var package = new AppCenterCore.Package (comp);
                foreach (var pkg_name in comp.get_pkgnames ()) {
                    package_list[pkg_name] = package;
                }
            });
        } catch (Error e) {
            error (e.message);
        }

        var icon = new AppStream.Icon ();
        icon.set_name ("distributor-logo");
        icon.set_kind (AppStream.IconKind.STOCK);

        var os_updates_component = new AppStream.Component ();
        os_updates_component.id = AppCenterCore.Package.OS_UPDATES_ID;
        os_updates_component.name = _("Operating System Updates");
        os_updates_component.summary = _("Updates to system components");
        os_updates_component.add_icon (icon);

        os_updates = new AppCenterCore.Package (os_updates_component);

        var control = new Pk.Control ();
        control.updates_changed.connect (updates_changed_callback);
    }

    private void updates_changed_callback () {
        var time_since_last_action = (new DateTime.now_local ()).difference (last_action) / GLib.TimeSpan.MILLISECOND;
        if (!has_tasks () && time_since_last_action >= PACKAGEKIT_ACTIVITY_TIMEOUT_MS) {
            info ("packages possibly changed by external program, refreshing cache");
            update_cache.begin (true);
        }
    }

    public bool has_tasks () {
        return task_count > 0;
    }

    public async Pk.Exit install_package (Package package, Pk.ProgressCallback cb, GLib.Cancellable cancellable) throws GLib.Error {
        task_count++;

        Pk.Exit exit_status = Pk.Exit.UNKNOWN;
        string[] packages_ids = {};
        foreach (var pkg_name in package.component.get_pkgnames ()) {
            packages_ids += pkg_name;
        }

        packages_ids += null;

        try {
            var results = yield client.resolve_async (Pk.Bitfield.from_enums (Pk.Filter.NEWEST, Pk.Filter.ARCH), packages_ids, cancellable, () => {});

            /*
             * If there were no packages found for the requested architecture,
             * try to resolve IDs by not searching for this architecture
             * e.g: filtering 32 bit only package on a 64 bit system
             */ 
            GenericArray<weak Pk.Package> package_array = results.get_package_array ();
            if (package_array.length == 0) {
                results = yield client.resolve_async (Pk.Bitfield.from_enums (Pk.Filter.NEWEST, Pk.Filter.NOT_ARCH), packages_ids, cancellable, () => {});
                package_array = results.get_package_array ();
            }

            packages_ids = {};
            package_array.foreach ((package) => {
                packages_ids += package.package_id;
            });

            packages_ids += null;

            results = yield client.install_packages_async (packages_ids, cancellable, cb);
            exit_status = results.get_exit_code ();
        } catch (Error e) {
            task_count--;
            throw e;
        }

        task_count--;
        return exit_status;
    }

    public async Pk.Exit update_package (Package package, Pk.ProgressCallback cb, GLib.Cancellable cancellable) throws GLib.Error {
        task_count++;

        Pk.Exit exit_status = Pk.Exit.UNKNOWN;
        string[] packages_ids = {};
        foreach (var pk_package in package.change_information.changes) {
            packages_ids += pk_package.get_id ();
        }

        packages_ids += null;

        try {
            sc.inhibit ();

            var results = yield client.update_packages_async (packages_ids, cancellable, cb);
            exit_status = results.get_exit_code ();
        } catch (Error e) {
            task_count--;
            throw e;
        } finally {
            sc.uninhibit ();
        }

        if (exit_status != Pk.Exit.SUCCESS) {
            throw new GLib.IOError.FAILED (Pk.Exit.enum_to_string (exit_status));
        } else {
            package.change_information.clear_update_info ();
        }

        task_count--;
        yield refresh_updates ();
        return exit_status;
    }

    public async Pk.Exit remove_package (Package package, Pk.ProgressCallback cb, GLib.Cancellable cancellable) throws GLib.Error {
        task_count++;

        Pk.Exit exit_status = Pk.Exit.UNKNOWN;
        string[] packages_ids = {};
        foreach (var pkg_name in package.component.get_pkgnames ()) {
            packages_ids += pkg_name;
        }

        packages_ids += null;

        try {
            var results = yield client.resolve_async (Pk.Bitfield.from_enums (Pk.Filter.INSTALLED, Pk.Filter.NEWEST), packages_ids, cancellable, () => {});
            packages_ids = {};
            results.get_package_array ().foreach ((package) => {
                packages_ids += package.package_id;
            });

            results = yield client.remove_packages_async (packages_ids, true, true, cancellable, cb);
            exit_status = results.get_exit_code ();
        } catch (Error e) {
            task_count--;
            throw e;
        }

        task_count--;
        yield refresh_updates ();
        return exit_status;
    }

    public async void get_updates () {
        task_count++;

        try {
            Pk.Results results = yield client.get_updates_async (0, cancellable, (t, p) => { });
            string[] packages_array = {};
            results.get_package_array ().foreach ((pk_package) => {
                packages_array += pk_package.get_id ();
                unowned string pkg_name = pk_package.get_name ();
                var package = package_list[pkg_name];
                if (package != null) {
                    package.latest_version = pk_package.get_version ();
                    package.change_information.changes.clear ();
                    package.change_information.details.clear ();
                }

                os_updates.change_information.changes.clear ();
                os_updates.change_information.details.clear ();
            });

            // We need a null to show to PackageKit that it's then end of the array.
            packages_array += null;

            results = yield client.get_details_async (packages_array , cancellable, (t, p) => { });
            results.get_details_array ().foreach ((pk_detail) => {
                var pk_package = new Pk.Package ();
                try {
                    pk_package.set_id (pk_detail.get_package_id ());

                    unowned string pkg_name = pk_package.get_name ();
                    var package = package_list[pkg_name];
                    if (package == null) {
                        package = os_updates;

                        var pkgnames = os_updates.component.pkgnames;
                        pkgnames += pkg_name;
                        os_updates.component.pkgnames = pkgnames;
                    }

                    package.change_information.changes.add (pk_package);
                    package.change_information.details.add (pk_detail);
                    package.update_state ();
                } catch (Error e) {
                    critical (e.message);
                }
            });
        } catch (Error e) {
            if (e.code != 19) {
                critical (e.message);
            }

            task_count--;
            return;
        }

        task_count--;
        updates_available ();
    }

    /**
     * Filters and checks if previously added driver components 
     * match a system modalias, are suitable for this system
     *
     * This could be done in get_components () block but since
     * scanning all modaliases takes some time , it is done here separately
     * to not interrupt populating UI lists with other applications
     */ 
    public async void get_drivers () {
        string[] aliases = yield scan_modaliases (null);
        foreach (var comp in drivers) {
            var provided = comp.get_provided_for_kind (AppStream.ProvidedKind.MODALIAS);
            if (provided != null) {
                foreach (string alias in aliases) {
                    if (provided.has_item (alias)) {
                        var package = new AppCenterCore.Package (comp);
                        foreach (var pkg_name in comp.get_pkgnames ()) {
                            package_list[pkg_name] = package;
                        }                        
                    }
                }
            }
        }
    }

    public async Gee.Collection<AppCenterCore.Package> get_installed_applications () {
        var packages = new Gee.TreeSet<AppCenterCore.Package> ();
        var installed = yield get_installed_packages ();
        foreach (var pk_package in installed) {
            var package = package_list[pk_package.get_name ()];
            if (package != null) {
                package.installed_packages.add (pk_package);
                package.latest_version = pk_package.get_version ();
                package.update_state ();
                packages.add (package);
            }
        }

        return packages;
    }

    public Gee.Collection<AppCenterCore.Package> get_applications_for_category (AppStream.Category category) {
        unowned GLib.GenericArray<AppStream.Component> components = category.get_components ();
        if (components.length == 0) {
            var category_array = new GLib.GenericArray<AppStream.Category> ();
            category_array.add (category);
            AppStream.utils_sort_components_into_categories (appstream_pool.get_components (), category_array, true);
            components = category.get_components ();
        }

        var apps = new Gee.TreeSet<AppCenterCore.Package> ();
        components.foreach ((comp) => {
            var package = get_package_for_component_id (comp.get_id ());
            if (package != null) {
                apps.add (package);
            }
        });

        return apps;
    }

    public Gee.Collection<AppCenterCore.Package> search_applications (string query, AppStream.Category? category) {
        var apps = new Gee.TreeSet<AppCenterCore.Package> ();
        GLib.GenericArray<weak AppStream.Component> comps = appstream_pool.search (query);
        if (category == null) {
            comps.foreach ((comp) => {
                var package = get_package_for_component_id (comp.get_id ());
                if (package != null) {
                    apps.add (package);
                }
            });
        } else {
            var cat_packages = get_applications_for_category (category);
            comps.foreach ((comp) => {
                var package = get_package_for_component_id (comp.get_id ());
                if (package != null && package in cat_packages) {
                    apps.add (package);
                }
            });
        }

        return apps;
    }

    public Pk.Package? get_app_package (string application, Pk.Bitfield additional_filters = 0) throws GLib.Error {
        task_count++;

        Pk.Package? package = null;
        var filter = Pk.Bitfield.from_enums (Pk.Filter.NEWEST);
        filter |= additional_filters;
        try {
            var results = client.search_names_sync (filter, { application, null }, cancellable, () => {});
            var array = results.get_package_array ();
            if (array.length > 0) {
                package = array.get (0);
            }
        } catch (Error e) {
            task_count--;
            throw e;
        }

        task_count--;
        return package;
    }

    private async void refresh_updates () {
        updating_cache = true;
        task_count++;

        try {
            Pk.Results results = yield client.get_updates_async (0, null, (t, p) => {});

            bool was_empty = updates_number == 0U;
            updates_number = get_package_count (results.get_package_array ());

            var application = Application.get_default ();
            if (was_empty && updates_number != 0U) {
                string title = ngettext ("Update Available", "Updates Available", updates_number);
                string body = ngettext ("%u update is available for your system", "%u updates are available for your system", updates_number).printf (updates_number);

                var notification = new Notification (title);
                notification.set_body (body);
                notification.set_icon (new ThemedIcon ("system-software-install"));
                notification.set_default_action ("app.show-updates");

                application.send_notification ("updates", notification);
            } else {
                application.withdraw_notification ("updates");
            }

#if HAVE_UNITY
            var launcher_entry = Unity.LauncherEntry.get_for_desktop_file ("io.elementary.appcenter.desktop");
            launcher_entry.count = updates_number;
            launcher_entry.count_visible = updates_number != 0U;
#endif
        } catch (Error e) {
            critical (e.message);
        }

        updating_cache = false;
        task_count--;
        refresh_in_progress = false;
    }

    private void update_restart_state (File restart_file) {
        if (restart_file.query_exists ()) {
            if (!restart_required) {
                string title = _("Restart Required");
                string body = _("Please restart your system to finalize updates");
                var notification = new Notification (title);
                notification.set_body (body);
                notification.set_icon (new ThemedIcon ("system-software-install"));
                notification.set_priority (NotificationPriority.URGENT);
                notification.set_default_action ("app.open-application");
                Application.get_default ().send_notification ("restart", notification);
            }

            restart_required = true;     
        } else if (restart_required) {
            restart_required = false;
        }
    }

    public uint get_package_count (GLib.GenericArray<weak Pk.Package> package_array) {
        bool os_update_found = false;
        var result_comp = new Gee.TreeSet<AppStream.Component> ();

        package_array.foreach ((pk_package) => {
            var package = package_list[pk_package.get_name ()];
            if (package != null) {
                result_comp.add (package.component);
            } else {
                os_update_found = true;
            }
        });

        uint size = result_comp.size;
        if (os_update_found) {
            size++;
        }

        return size;
    }

    public void cancel_updates (bool cancel_timeout) {
        cancellable.cancel ();

        if (update_cache_timeout_id > 0 && cancel_timeout) {
            Source.remove (update_cache_timeout_id);
            update_cache_timeout_id = 0;
            last_cache_update = null;
        }

        cancellable = new GLib.Cancellable ();
        refresh_in_progress = false;
    }

    public async void update_cache (bool force = false) {
        debug ("update cache called %s", force.to_string ());
        bool success = false;

        /* Make sure only one update cache can run at a time */
        if (refresh_in_progress) {
            debug ("Update cache already in progress - returning");
            return;
        } else {
            refresh_in_progress = true;
        }


        if (update_cache_timeout_id > 0) {
            if (force) {
                debug ("Forced update_cache called when there is an on-going timeout - cancelling timeout");
                Source.remove (update_cache_timeout_id);
                update_cache_timeout_id = 0;
            } else {
                debug ("Refresh timeout running and not forced - returning");
                refresh_in_progress = false;
                return;
            }
        }

        /* One cache update a day, keeps the doctor away! */
        if (force || last_cache_update == null ||
            (new DateTime.now_local ()).difference (last_cache_update) / GLib.TimeSpan.SECOND >= SECONDS_BETWEEN_REFRESHES) {
            var nm = NetworkMonitor.get_default ();
            if (nm.get_network_available ()) {
                debug ("New refresh task");

                try {
                    Pk.Results results = yield client.refresh_cache_async (false, cancellable, (t, p) => { });
                    success = results.get_exit_code () == Pk.Exit.SUCCESS;
                    last_cache_update = new DateTime.now_local ();
                } catch (Error e) {
                    critical ("Update_cache: Refesh cache async failed - %s", e.message);
                }

                if (success) {
                    refresh_updates.begin ();
                }

            } else {
                refresh_in_progress = false; //Stops new timeout while no network.
            }
        } else {
            debug ("Too soon to refresh and not forced");
        }


        if (refresh_in_progress) {
            update_cache_timeout_id = GLib.Timeout.add_seconds (SECONDS_BETWEEN_REFRESHES, () => {
                update_cache_timeout_id = 0;
                update_cache.begin (true);
                return GLib.Source.REMOVE;
            });

            refresh_in_progress = success;
        } // Otherwise updates and timeout were cancelled during refresh, or no network present.
    }

    public async Gee.TreeSet<Pk.Package> get_installed_packages () {
        task_count++;

        Pk.Bitfield filter = Pk.Bitfield.from_enums (Pk.Filter.INSTALLED, Pk.Filter.NEWEST);
        var installed = new Gee.TreeSet<Pk.Package> ();

        try {
            Pk.Results results = yield client.get_packages_async (filter, null, (prog, type) => {});
            results.get_package_array ().foreach ((pk_package) => {
                installed.add (pk_package);
            });

        } catch (Error e) {
            critical (e.message);
        }

        task_count--;
        return installed;
    }

    public AppCenterCore.Package? get_package_for_component_id (string id) {
        foreach (var package in package_list.values) {
            if (package.component.id == id) {
                return package;
            }
        }

        return null;
    }

    public AppCenterCore.Package? get_package_for_desktop_id (string desktop_id) {
        foreach (var package in package_list.values) {
            if (package.component.get_desktop_id () == desktop_id) {
                return package;
            }
        }

        return null;
    }

    /**
     * Scans for system modaliases
     *
     * This is mostly just a Vala version of UbuntuDrivers system_modaliases () function:
     * http://bazaar.launchpad.net/~ubuntu-branches/ubuntu/vivid/ubuntu-drivers-common/vivid/view/head:/UbuntuDrivers/detect.py#L23
     */
    private async static string[] scan_modaliases (owned File? root) {
        if (root == null) {
            root = File.new_for_path ("/sys/devices");
        }

        string[] aliases = {};
        try {
            var enumerator = yield root.enumerate_children_async ("standard::*", FileQueryInfoFlags.NOFOLLOW_SYMLINKS);
            FileInfo? info = null;
            while ((info = enumerator.next_file (null)) != null) {
                string? alias = null;

                if (info.get_file_type () == FileType.DIRECTORY) {
                    var subdir = root.resolve_relative_path (info.get_name ());
                    string[] subaliases = yield scan_modaliases (subdir);
                    foreach (string subalias in subaliases) {
                        aliases += subalias;
                    }
                } else if (info.get_name () == "modalias") {
                    var subfile = root.resolve_relative_path (info.get_name ());
                    uint8[] contents;
                    yield subfile.load_contents_async (null, out contents, null);

                    alias = ((string)contents).strip ();
                } else if ("ssb" in root.get_path () && info.get_name () == "uevent") {
                    var subfile = root.resolve_relative_path (info.get_name ());
                    uint8[] contents;
                    yield subfile.load_contents_async (null, out contents, null);

                    string[] lines = ((string)contents).split ("\n");
                    foreach (string line in lines) {
                        string[] tokens = line.split ("=");
                        if (tokens.length == 2 && tokens[0] == "MODALIAS") {
                            alias = tokens[1].strip ();
                            break;
                        }
                    }
                }

                if (alias == null) {
                    continue;
                }

                string driver_link = Path.build_filename (root.get_path (), "driver");
                string modlink = Path.build_filename (driver_link, "module");

                if (FileUtils.test (driver_link, FileTest.IS_SYMLINK) && !FileUtils.test (modlink, FileTest.IS_SYMLINK)) {
                    continue;
                }

                aliases += alias;
            }
        } catch (Error e) {
            warning (e.message);
        }

        return aliases;
    }

    private static GLib.Once<Client> instance;
    public static unowned Client get_default () {
        return instance.once (() => { return new Client (); });
    }
}
