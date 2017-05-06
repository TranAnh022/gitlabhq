/* global Flash */

import AssigneeTitle from './assignee_title';
import Assignees from './assignees';

import Store from '../../stores/sidebar_store';
import Mediator from '../../sidebar_mediator';

import eventHub from '../../event_hub';

export default {
  name: 'SidebarAssignees',
  data() {
    return {
      mediator: new Mediator(),
      store: new Store(),
      loading: false,
      field: '',
    };
  },
  components: {
    'assignee-title': AssigneeTitle,
    assignees: Assignees,
  },
  methods: {
    assignSelf() {
      // Notify gl dropdown that we are now assigning to current user
      this.$el.parentElement.dispatchEvent(new Event('assignYourself'));

      this.mediator.assignYourself();
      this.saveAssignees();
    },
    saveAssignees() {
      this.loading = true;

<<<<<<< HEAD
      this.mediator.saveAssignees(this.field)
        .then(() => {
          this.loading = false;
        })
        .catch(() => {
          this.loading = false;
=======
      function setLoadingFalse() {
        this.loading = false;
      }

      this.mediator.saveAssignees(this.field)
        .then(setLoadingFalse.bind(this))
        .catch(() => {
          setLoadingFalse();
>>>>>>> 6ce1df41e175c7d62ca760b1e66cf1bf86150284
          return new Flash('Error occurred when saving assignees');
        });
    },
  },
  created() {
    this.removeAssignee = this.store.removeAssignee.bind(this.store);
    this.addAssignee = this.store.addAssignee.bind(this.store);
    this.removeAllAssignees = this.store.removeAllAssignees.bind(this.store);

    // Get events from glDropdown
    eventHub.$on('sidebar.removeAssignee', this.removeAssignee);
    eventHub.$on('sidebar.addAssignee', this.addAssignee);
    eventHub.$on('sidebar.removeAllAssignees', this.removeAllAssignees);
    eventHub.$on('sidebar.saveAssignees', this.saveAssignees);
  },
  beforeDestroy() {
    eventHub.$off('sidebar.removeAssignee', this.removeAssignee);
    eventHub.$off('sidebar.addAssignee', this.addAssignee);
    eventHub.$off('sidebar.removeAllAssignees', this.removeAllAssignees);
    eventHub.$off('sidebar.saveAssignees', this.saveAssignees);
  },
  beforeMount() {
    this.field = this.$el.dataset.field;
  },
  template: `
    <div>
      <assignee-title
        :number-of-assignees="store.assignees.length"
        :loading="loading"
        :editable="store.editable"
      />
      <assignees
        class="value"
        :root-path="store.rootPath"
        :users="store.assignees"
        :editable="store.editable"
        @assign-self="assignSelf"
      />
    </div>
  `,
};
