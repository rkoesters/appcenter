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

namespace AppCenterCore {
    public class Client : Object {
        public signal void updates_available ();
        public signal void tasks_finished ();
        public bool connected { public get; private set; }

        private Gee.LinkedList<Pk.Task> task_list;
        private Gee.HashMap<string, AppCenterCore.Package> package_list;
        private AppStream.Database appstream_database;

        private Client () {
            task_list = new Gee.LinkedList<Pk.Task> ();
            package_list = new Gee.HashMap<string, AppCenterCore.Package> (null, null);

            var datapool = new AppStream.DataPool ();
            datapool.update ();
            appstream_database = new AppStream.Database ();
            appstream_database.open ();
        }

        public bool has_tasks () {
            return !task_list.is_empty;
        }

        private Pk.Task request_task () {
            Pk.Task task = new Pk.Task ();
            task_list.add (task);
            return task;
        }

        private void release_task (Pk.Task task) {
            task_list.remove (task);
            if (task_list.is_empty) {
                tasks_finished ();
            }
        }

        public async void install_packages (Gee.TreeSet<Package> packages, Pk.ProgressCallback cb) throws GLib.Error {
            Pk.Task install_task = request_task ();
            string[] packages_ids = {};
            foreach (var package in packages) {
                packages_ids += package.package_id;
            }

            try {
                yield install_task.install_packages_async (packages_ids, null, cb);
            } catch (Error e) {
                throw e;
            }

            release_task (install_task);
        }

        public async void update_packages (Gee.TreeSet<Package> packages, Pk.ProgressCallback cb) throws GLib.Error {
            Pk.Task update_task = request_task ();
            string[] packages_ids = {};
            foreach (var package in packages) {
                packages_ids += package.package_id;
            }

            try {
                yield update_task.update_packages_async (packages_ids, null, cb);
            } catch (Error e) {
                throw e;
            }

            release_task (update_task);
        }

        public async void remove_packages (Gee.TreeSet<Package> packages, Pk.ProgressCallback cb) throws GLib.Error {
            Pk.Task remove_task = request_task ();
            string[] packages_ids = {};
            foreach (var package in packages) {
                packages_ids += package.package_id;
            }

            try {
                yield remove_task.remove_packages_async (packages_ids, true, true, null, cb);
            } catch (Error e) {
                throw e;
            }

            release_task (remove_task);
        }

        public async void refresh_updates () {
            Pk.Task update_task = request_task ();
            Pk.Task details_task = request_task ();
            try {
                Pk.Results result = yield update_task.get_updates_async (Pk.Filter.INSTALLED, null, (t, p) => { });
                var packages = new Gee.HashMap<string, Pk.Package> (null, null);
                result.get_package_array ().foreach ((pk_package) => {
                    packages.set (pk_package.get_id (), pk_package);
                });

                // We need a null to show to PackageKit that it's then end of the array.
                string[] packages_array = packages.keys.to_array ();
                packages_array += null;

                Pk.Results result2 = yield details_task.get_details_async (packages_array , null, (t, p) => { });
                result2.get_details_array ().foreach ((pk_detail) => {
                    var pk_package = packages.get (pk_detail.get_package_id ());
                    AppCenterCore.Package package = package_list.get (pk_package.get_name ());
                    if (package == null) {
                        package = new AppCenterCore.Package (pk_package);
                        package_list.set (pk_package.get_name (), package);
                    }

                    pk_package.size = pk_detail.size;
                    package.update_package = pk_package;
                });
            } catch (Error e) {
                critical (e.message);
            }

            release_task (details_task);
            release_task (update_task);
            updates_available ();
        }

        public async void refresh_cache (Pk.ProgressCallback cb) {
            Pk.Task cache_task = request_task ();
            try {
                yield cache_task.refresh_cache_async (false, null, cb);
            } catch (Error e) {
                critical (e.message);
            }

            release_task (cache_task);
        }

        public async Gee.Collection<AppCenterCore.Package> get_installed_applications () {
            Pk.Task packages_task = request_task ();
            var packages = new Gee.TreeSet<AppCenterCore.Package> ();

            try {
                var install_filter = Utils.bitfield_from_filter (Pk.Filter.INSTALLED);
                var new_filter = Utils.bitfield_from_filter (Pk.Filter.NEWEST);
                Pk.Results result = yield packages_task.get_packages_async (install_filter|new_filter, null,
                        (prog, type) => {});
                result.get_package_array ().foreach ((pk_package) => {
                    AppCenterCore.Package package = package_list.get (pk_package.get_name ());
                    if (package == null) {
                        package = new AppCenterCore.Package (pk_package);
                        package_list.set (pk_package.get_name (), package);
                    }

                    package.installed = true;
                    packages.add (package);
                });
            } catch (Error e) {
                critical (e.message);
            }

            release_task (packages_task);
            return packages;
        }

        public Gee.Collection<AppCenterCore.Package> get_cached_applications () {
            return package_list.values;
        }

        public async Gee.Collection<AppCenterCore.Package> get_applications (Pk.Bitfield filter, Pk.Group group, GLib.Cancellable? cancellable = null) {
            Pk.Task packages_task = request_task ();
            var packages = new Gee.TreeSet<AppCenterCore.Package> ();

            try {
                var group_string = Pk.Group.enum_to_string (group);
                Pk.Results result = yield packages_task.search_groups_async (filter, {group_string, null}, cancellable, () => {});
                result.get_package_array ().foreach ((pk_package) => {
                    AppCenterCore.Package package = package_list.get (pk_package.get_name ());
                    if (package == null) {
                        package = new AppCenterCore.Package (pk_package);
                        package_list.set (pk_package.get_name (), package);
                    }

                    packages.add (package);
                });
            } catch (Error e) {
                critical (e.message);
            }

            release_task (packages_task);
            return packages;
        }

        public Gee.Collection<AppStream.Component> get_component_for_app (string app) {
            var comps = appstream_database.find_components_by_term ("pkg:%s".printf (app), null);
            var components = new Gee.TreeSet<AppStream.Component> ();
            comps.foreach ((component) => {
                components.add (component);
            });

            return components;
        }

        private static GLib.Once<Client> instance;
        public static unowned Client get_default () {
            return instance.once (() => { return new Client (); });
        }
    }
}