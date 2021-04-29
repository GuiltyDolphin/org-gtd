;;; gtde-oo-tests.el --- Tests for gtde-oo.el -*- lexical-binding: t -*-
;;; Code:


(require 'dash)
(require 'gtde-json)
(require 'gtde-org)


(defun gtde-test--find-test-case-file (pt basename)
  "Find the test case file path for BASENAME and the given project type PT."
  (format "tests/cases/%s.%s" basename pt))

(defun gtde--map-class-leaves (fun classes)
  "Map FUN over leaf classes of CLASSES.

CLASSES is traversed left-to-right, including children."
  (unless (null classes)
    (let* ((current (car classes))
           (right1 (gtde--map-class-leaves fun (eieio-class-children current)))
           (right2 (gtde--map-class-leaves fun (cdr classes))))
      (if (null right1)
          (cons (funcall fun current) right2)
        (-concat right1 right2)))))

(defmacro gtde-tests--should-error-with-match (form regex)
  "Evaluate FORM and check that it signals an error whose description matches REGEX."
  (declare (indent 1))
  `(should (string-match-p ,regex (cadr (should-error ,form)))))

(defmacro gtde-test--with-temp-file (prefix suffix text fvar &rest body)
  "Create a temporary file and execute BODY like `progn', with FVAR bound to the file name.

PREFIX is the prefix used for the filename, and likewise SUFFIX is the suffix.

TEXT is inserted automatically into the file."
  (declare (indent 4) (debug t))
  (let ((temp-file (make-symbol "temp-file"))
        (buffers-for-temp-file (make-symbol "buffers-for-temp-file")))
    `(let ((,temp-file (make-temp-file ,prefix nil ,suffix ,text)))
       (unwind-protect
           (let ((,fvar ,temp-file)) (progn ,@body))
         (let ((,buffers-for-temp-file (-filter (lambda (buffer) (equal (buffer-file-name buffer) ,temp-file)) (buffer-list))))
           (-each ,buffers-for-temp-file (lambda (buffer)
                                           (with-current-buffer buffer
                                             (set-buffer-modified-p nil)
                                             (kill-buffer buffer)))))
         (delete-file ,temp-file)))))

(defmacro gtde-test--with-temp-file-for-project (pt prefix text fvar &rest body)
  "Create a temporary file with prefix PREFIX and execute BODY like `progn', with FVAR bound to the name of the temporary file.

TEXT is inserted into the new file.
PT is the project-type to create a file for."
  (declare (indent 4) (debug t))
  (let ((suffix (if (eq pt 'org) ".org" (if (eq pt 'json) "json"))))
    `(gtde-test--with-temp-file ,prefix ,suffix ,text ,fvar ,@body)))

(defun gtde-test--find-item-by-id-in-file (project-type id file)
  "Find the item with given ID in FILE with PROJECT-TYPE."
  (let ((db (gtde--build-db-from-files project-type (list file))))
    (gtde--db-get-entry db id)))

(defmacro gtde-test--test-each-project-type (basename pts ptvar doc &rest body)
  "Define a test for each project type in PTS.

BASENAME is the base name of the test.

In each test, PTVAR holds the value of the current project type.

DOC is the test documentation.
BODY is the test body."
  (declare (indent 3) (debug t))
  (let ((pts (eval pts)))
    (dolist (pt pts)
      (let ((test-name (intern (format "gtde-oo-test:%s:%s" basename pt))))
        ;;`(ert-deftest ,(make-symbol (format "gtde-oo-test:%s:%s" basename pt)) ()
        (eval `(ert-deftest ,test-name ()
                 ,doc
                 (let ((,ptvar ',pt))
                   ,@body)))))))


;;;;;;;;;;;;;;;;;
;;;;; Tests ;;;;;
;;;;;;;;;;;;;;;;;


(ert-deftest gtde-oo-test:base ()
  "Tests for `gtde--base'."
  ;; class should be abstract, we should not be able to make an instance
  (gtde-tests--should-error-with-match (gtde--base) "is abstract$"))

(ert-deftest gtde-oo-test:gtde--from-org:all-nonabstract-leaves-have-type ()
  "All non-abstract leaf classes of `gtde--from-org' must have a non-NIL default value set for the type-name property."
  (let ((leaves-with-type-name (gtde--map-class-leaves (lambda (c) (cons c (gtde--oref-default-or-nil c type-name))) '(gtde--from-org))))
    (--each leaves-with-type-name (-let (((c . k) it)) (should-not (equal (cons c nil) (cons c k)))))))

(gtde-test--test-each-project-type build-db-from-files '(org json) pt
  "Tests for `gtde--build-db-from-files'."
  (let ((db (gtde--build-db-from-files pt (list (gtde-test--find-test-case-file pt "01-simple")))))

    ;; correct IDs should be parsed into items
    (should (equal (-sort #'string-lessp (hash-table-keys (oref db table)))
                   '("02-project" "03-action-standalone" "04-action-with-project" "05-waiting-for-with-project")))
    (let ((config (oref db global-config))
          (project (gtde--db-get-entry db "02-project"))
          (action-standalone (gtde--db-get-entry db "03-action-standalone"))
          (action-with-project (gtde--db-get-entry db "04-action-with-project"))
          (waiting-for-with-project (gtde--db-get-entry db "05-waiting-for-with-project")))

      ;; testing config
      (should (equal 'gtde--config (eieio-object-class config)))
      (should (equal (list (gtde--status :display "ACTIVE" :is-active t)
                           (gtde--status :display "COMPLETE" :is-active nil)
                           (gtde--status :display "CANCELLED" :is-active nil))
                     (gtde--get-statuses-for-type config "project")))

      ;; testing project
      (should (equal 'gtde--project (eieio-object-class project)))
      (should (equal "02-project" (oref project id)))
      (should (equal "Test project" (oref project title)))
      (should (equal (gtde--status :display "COMPLETE" :is-active nil) (gtde--get-status project)))
      (should-not (gtde--is-active project))

      ;; testing action-standalone
      (should (equal 'gtde--next-action (eieio-object-class action-standalone)))
      (should (equal "03-action-standalone" (oref action-standalone id)))
      (should (equal "A test standalone action" (oref action-standalone title)))
      (should (equal (gtde--status :display "NEXT" :is-active t) (gtde--get-status action-standalone)))
      (should (gtde--is-active action-standalone))

      ;; testing action-with-project
      (should (equal 'gtde--next-action (eieio-object-class action-with-project)))
      (should (equal "04-action-with-project" (oref action-with-project id)))
      (should (equal '("02-project") (oref action-with-project superior-projects)))
      (should (equal "Action of \"a test project\"" (oref action-with-project title)))
      (should (equal (gtde--status :display "DONE" :is-active nil) (gtde--get-status action-with-project)))
      (should (equal (gtde--some (list (gtde--context :name "test_context"))) (oref action-with-project context)))
      (should-not (gtde--is-active action-with-project))

      ;; testing waiting-for-with-project
      (should (equal 'gtde--waiting-for (eieio-object-class waiting-for-with-project)))
      (should (equal "05-waiting-for-with-project" (oref waiting-for-with-project id)))
      (should (equal '("02-project") (oref waiting-for-with-project superior-projects)))
      (should (equal (gtde--status :display "WAITING" :is-active t) (gtde--get-status waiting-for-with-project)))
      (should (gtde--is-active waiting-for-with-project))
      (should (equal "Waiting for of \"a test project\"" (oref waiting-for-with-project title)))))

  ;; unsupported GTD type
  (should (equal "something_unsupported"
                 (cdr (should-error (gtde--build-db-from-files pt (list (gtde-test--find-test-case-file pt "02-bad"))) :type 'gtde--unsupported-gtd-type)))))

(ert-deftest gtde-oo-test:parse-from-raw ()
  "Tests for `gtde--parse-from-raw'."
  (let ((config1 (gtde--config :statuses `(("project" . ,(list (gtde--status :display "ACTIVE")))) :context-tag-regex "@\\(.*\\)"))
        (config2 (gtde--config :statuses `(("project" . ,(list (gtde--status :display "ACTIVE")))) :context-tag-regex "@.*")))
    (should (equal (gtde--context :name "test") (gtde--parse-from-raw 'org #'gtde--context config1 "@test")))
    (should (equal (gtde--context :name "@test") (gtde--parse-from-raw 'org #'gtde--context config2 "@test")))))

(gtde-test--test-each-project-type write-item-to-file '(org json) pt
  "Tests for `gtde--write-item-to-file'."
  ;; all fields of projects and actions can be written
  (let ((example-action (gtde--next-action :title "Modified action title" :id "01-test-action" :status (gtde--status :display "DONE" :is-active nil)))
        (example-project (gtde--project :title "Modified title" :id "01-test-project" :status (gtde--status :display "INACTIVE" :is-active nil)))
        (case-text (if (eq pt 'org)
"* Test config
:PROPERTIES:
:GTDE_IS_CONFIG: t
:GTDE_PROJECT_STATUSES: ACTIVE | INACTIVE
:GTDE_NEXT_ACTION_STATUSES: NEXT | DONE
:GTDE_CONTEXT_TAG_REGEX: @\\(.*\\)
:END:
* Test action
:PROPERTIES:
:ID: 01-test-action
:GTDE_TYPE: next_action
:GTDE_STATUS: NEXT
:END:
* Test project
:PROPERTIES:
:ID: 01-test-project
:GTDE_TYPE: project
:GTDE_STATUS: ACTIVE
:END:" (if (eq pt 'json)
"{
  \"config\": {
      \"GTDE_IS_CONFIG\": true,
      \"GTDE_PROJECT_STATUSES\": \"ACTIVE | INACTIVE\",
      \"GTDE_NEXT_ACTION_STATUSES\": \"NEXT | DONE\",
      \"GTDE_CONTEXT_TAG_REGEX\": \"@\\\\(.*\\\\)\"
  },
  \"01-test-action\": {
      \"title\": \"Test action\",
      \"id\": \"01-test-action\",
      \"GTDE_TYPE\": \"next_action\",
      \"GTDE_STATUS\": \"NEXT\"
  },
  \"01-test-project\": {
      \"title\": \"Test project\",
      \"id\": \"01-test-project\",
      \"GTDE_TYPE\": \"project\",
      \"GTDE_STATUS\": \"ACTIVE\"
  }
}"))))
      (gtde-test--with-temp-file-for-project pt "test-file" case-text fvar
        (gtde--write-item-to-file pt fvar example-project)
        (gtde--write-item-to-file pt fvar example-action)
        (should (equal example-project (gtde-test--find-item-by-id-in-file pt "01-test-project" fvar)))
        (should (equal example-action (gtde-test--find-item-by-id-in-file pt "01-test-action" fvar))))))

(ert-deftest gtde-oo-test:build-db-from-files:no-such-file ()
  "Testing `gtde--build-db-from-files' when passed nonexistent files."
  ;;(should-error (gtde--parse-from-raw nil #'gtde--status
  (dolist (pt '(org json))
    (gtde-test--with-temp-file-for-project pt "test-file" "" fvar
      (delete-file fvar)
      (should-error (gtde--build-db-from-files pt (list fvar)) :type 'gtde--no-such-file))))

(gtde-test--test-each-project-type unknown-project-status '(org json) pt
  "An unknown project status is specified (loaded from file)."
  (let ((res (should-error (gtde--build-db-from-files pt (list (gtde-test--find-test-case-file pt "04-unknown-status"))) :type 'gtde--unknown-status)))
    (should (equal (cadr res) 'gtde--project))
    (should (equal (cddr res) "NOTVALID"))))

(gtde-test--test-each-project-type unknown-project-status-2 '(org json) pt
  "An unknown project status is specified."
  (let* ((config (gtde--config :statuses `(("project" . ,(list (gtde--status :display "DONE" :is-active t))))))
         (res (should-error (gtde--parse-from-raw-for pt 'gtde--next-action 'gtde--status config "TODO") :type 'gtde--unknown-status)))
    (should (equal (cadr res) 'gtde--next-action))
    (should (equal (cddr res) "TODO"))))

(gtde-test--test-each-project-type unknown-action-status '(org json) pt
  "An unknown action status is specified."
  (let* ((config (gtde--config :statuses `(("next_action" . ,(list (gtde--status :display "ACTION" :is-active t))))))
         (res (should-error (gtde--parse-from-raw-for pt 'gtde--next-action 'gtde--status config "TEST") :type 'gtde--unknown-status)))
    (should (equal (cadr res) 'gtde--next-action))
    (should (equal (cddr res) "TEST"))))

(gtde-test--test-each-project-type unknown-waiting-for-status '(org json) pt
  "An unknown waiting for status is specified.

The NEXT status is specified for next actions, but not waiting fors, so should not be accepted as a waiting for status."
  (let* ((config (gtde--config :statuses `(("next_action" . ,(list (gtde--status :display "NEXT" :is-active t))) ("waiting_for" . ,(list (gtde--status :display "WAITING" :is-active t))))))
         (res (should-error (gtde--parse-from-raw-for pt 'gtde--waiting-for 'gtde--status config "NEXT") :type 'gtde--unknown-status)))
    (should (equal (cadr res) 'gtde--waiting-for))
    (should (equal (cddr res) "NEXT"))))


(provide 'gtde-oo-tests)
;;; gtde-oo-tests.el ends here
