;;; compiler.lisp ---

;; Copyright (C) 2012, 2013 David Vazquez
;; Copyright (C) 2012 Raimon Grau

;; JSCL is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of the
;; License, or (at your option) any later version.
;;
;; JSCL is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
;; General Public License for more details.
;;
;; You should have received a copy of the GNU General Public License
;; along with JSCL.  If not, see <http://www.gnu.org/licenses/>.

;;;; Compiler

(/debug "loading compiler.lisp!")

;;; Translate the Lisp code to Javascript. It will compile the special
;;; forms. Some primitive functions are compiled as special forms
;;; too. The respective real functions are defined in the target (see
;;; the beginning of this file) as well as some primitive functions.

(define-js-macro selfcall (&body body)
  `(call (function () ,@body)))

(define-js-macro method-call (x method &rest args)
  `(call (get ,x ,method) ,@args))

(define-js-macro nargs ()
  `(- (get |arguments| |length|) 1))

(define-js-macro arg (n)
  `(property |arguments| (+ ,n 1)))

;;; Runtime

(define-js-macro internal (x)
  `(get |internals| ,x))

(define-js-macro call-internal (name &rest args)
  `(method-call |internals| ,name ,@args))


;;;; Target
;;;
;;; Targets allow us to accumulate Javascript statements

(def!struct target
    code)

(defvar *target*)

(defun push-to-target (js &optional (target *target*))
  (push js (target-code target)))

(defun target-statements (&optional (target *target*))
  (reverse (target-code target)))

;;; Emit an expression or statement into target.
;;;
;;; If the optional argument VAR is provideed, EXPR must be an
;;; expression, the result of the expression will be assigned into
;;; VAR. VAR is returned.
;;;
(defun emit (expr &optional var (target *target*))
  (when (eq var t)
    (setq var (gvarname))
    (emit `(var ,var)))
  (let ((stmt (if var `(= ,var ,expr) expr)))
    (push-to-target stmt target)
    var))


;;; Create a set of new targets and initialize them. Then execute
;;; BODY.  Bindings is a list of the form (TARGET-NAME FORM). FORM is
;;; evaluated with TARGET-NAME bound to the newly created target, and
;;; set as the current target (*TARGET*).
(defmacro let-target ((name) form &body body)
  `(let ((,name
          (let ((*target* (make-target)))
            ,form
            *target*)))
     ,@body))



;;; A Form can return a multiple values object calling VALUES, like
;;; values(arg1, arg2, ...). It will work in any context, as well as
;;; returning an individual object. However, if the special variable
;;; `*multiple-value-p*' is NIL, is granted that only the primary
;;; value will be used, so we can optimize to avoid the VALUES
;;; function call.
(defvar *multiple-value-p* nil)

;;; It is bound dinamically to the number of nested calls to
;;; `convert'. Therefore, a form is being compiled as toplevel if it
;;; is zero.
(defvar *convert-level* -1)

;;; Contain a symbol describin the Javascript variable to which the
;;; current form being compiled should assign the result of the that
;;; form.
(defvar *out*)


;;; Environment

(def!struct binding
  name
  type
  value
  declarations)

(def!struct lexenv
  variable
  function
  block
  gotag)

(defun lookup-in-lexenv (name lexenv namespace)
  (find name (ecase namespace
                (variable (lexenv-variable lexenv))
                (function (lexenv-function lexenv))
                (block    (lexenv-block    lexenv))
                (gotag    (lexenv-gotag    lexenv)))
        :key #'binding-name))

(defun push-to-lexenv (binding lexenv namespace)
  (ecase namespace
    (variable (push binding (lexenv-variable lexenv)))
    (function (push binding (lexenv-function lexenv)))
    (block    (push binding (lexenv-block    lexenv)))
    (gotag    (push binding (lexenv-gotag    lexenv)))))

(defun extend-lexenv (bindings lexenv namespace)
  (let ((env (copy-lexenv lexenv)))
    (dolist (binding (reverse bindings) env)
      (push-to-lexenv binding env namespace))))


(defvar *environment*)
(defvar *variable-counter*)

(defun gvarname (&optional symbol)
  (declare (ignore symbol))
  (incf *variable-counter*)
  (make-symbol (concat "v" (integer-to-string *variable-counter*))))

(defun translate-variable (symbol)
  (awhen (lookup-in-lexenv symbol *environment* 'variable)
    (binding-value it)))

(defun extend-local-env (args)
  (let ((new (copy-lexenv *environment*)))
    (dolist (symbol args new)
      (let ((b (make-binding :name symbol :type 'variable :value (gvarname symbol))))
        (push-to-lexenv b new 'variable)))))

;;; Toplevel compilations
(defvar *toplevel-compilations*)

(defun %compile-defmacro (name lambda)
  (let ((binding (make-binding :name name :type 'macro :value lambda)))
    (push-to-lexenv binding  *environment* 'function))
  name)

(defun global-binding (name type namespace)
  (or (lookup-in-lexenv name *environment* namespace)
      (let ((b (make-binding :name name :type type :value nil)))
        (push-to-lexenv b *environment* namespace)
        b)))

(defun claimp (symbol namespace claim)
  (let ((b (lookup-in-lexenv symbol *environment* namespace)))
    (and b (member claim (binding-declarations b)))))

(defun !proclaim (decl)
  (case (car decl)
    (special
     (dolist (name (cdr decl))
       (let ((b (global-binding name 'variable 'variable)))
         (push 'special (binding-declarations b)))))
    (notinline
     (dolist (name (cdr decl))
       (let ((b (global-binding name 'function 'function)))
         (push 'notinline (binding-declarations b)))))
    (constant
     (dolist (name (cdr decl))
       (let ((b (global-binding name 'variable 'variable)))
         (push 'constant (binding-declarations b)))))))

#+jscl
(fset 'proclaim #'!proclaim)

(defun %define-symbol-macro (name expansion)
  (let ((b (make-binding :name name :type 'macro :value expansion)))
    (push-to-lexenv b *environment* 'variable)
    name))

#+jscl
(defmacro define-symbol-macro (name expansion)
  `(%define-symbol-macro ',name ',expansion))



;;; Report functions which are called but not defined

(defvar *fn-info* '())

(def!struct fn-info
  symbol
  defined
  called)

(defun find-fn-info (symbol)
  (let ((entry (find symbol *fn-info* :key #'fn-info-symbol)))
    (unless entry
      (setq entry (make-fn-info :symbol symbol))
      (push entry *fn-info*))
    entry))

(defun fn-info (symbol &key defined called)
  (let ((info (find-fn-info symbol)))
    (when defined
      (setf (fn-info-defined info) defined))
    (when called
      (setf (fn-info-called info) called))))

(defun report-undefined-functions ()
  (dolist (info *fn-info*)
    (let ((symbol (fn-info-symbol info)))
      (when (and (fn-info-called info)
                 (not (fn-info-defined info)))
        (warn "The function `~a' is undefined.~%" symbol))))
  (setq *fn-info* nil))



;;; Special forms

(defvar *compilations*
  (make-hash-table))

(defmacro define-compilation (name args &body body)
  ;; Creates a new primitive `name' with parameters args and
  ;; @body. The body can access to the local environment through the
  ;; variable *ENVIRONMENT*.
  `(setf (gethash ',name *compilations*)
         (lambda ,args (block ,name ,@body))))

(define-compilation if (condition true &optional false)
  (emit `(if (!== ,(convert condition) ,(convert nil))
             ,(convert-to-block true *out* *multiple-value-p*)
             ,(convert-to-block false *out* *multiple-value-p*))))


(defvar *ll-keywords* '(&optional &rest &key))

(defun list-until-keyword (list)
  (if (or (null list) (member (car list) *ll-keywords*))
      nil
      (cons (car list) (list-until-keyword (cdr list)))))

(defun ll-section (keyword ll)
  (list-until-keyword (cdr (member keyword ll))))

(defun ll-required-arguments (ll)
  (list-until-keyword ll))

(defun ll-optional-arguments-canonical (ll)
  (mapcar #'ensure-list (ll-section '&optional ll)))

(defun ll-optional-arguments (ll)
  (mapcar #'car (ll-optional-arguments-canonical ll)))

(defun ll-rest-argument (ll)
  (let ((rest (ll-section '&rest ll)))
    (when (cdr rest)
      (error "Bad lambda-list `~S'." ll))
    (car rest)))

(defun ll-keyword-arguments-canonical (ll)
  (flet ((canonicalize (keyarg)
	   ;; Build a canonical keyword argument descriptor, filling
	   ;; the optional fields. The result is a list of the form
	   ;; ((keyword-name var) init-form svar).
           (let ((arg (ensure-list keyarg)))
             (cons (if (listp (car arg))
                       (car arg)
                       (list (intern (symbol-name (car arg)) "KEYWORD") (car arg)))
                   (cdr arg)))))
    (mapcar #'canonicalize (ll-section '&key ll))))

(defun ll-keyword-arguments (ll)
  (mapcar (lambda (keyarg) (second (first keyarg)))
	  (ll-keyword-arguments-canonical ll)))

(defun ll-svars (lambda-list)
  (let ((args
         (append
          (ll-keyword-arguments-canonical lambda-list)
          (ll-optional-arguments-canonical lambda-list))))
    (remove nil (mapcar #'third args))))

(defun lambda-check-argument-count
    (n-required-arguments n-optional-arguments rest-p)
  ;; Note: Remember that we assume that the number of arguments of a
  ;; call is at least 1 (the values argument).
  (let ((min n-required-arguments)
        (max (if rest-p 'n/a (+ n-required-arguments n-optional-arguments))))
    (block nil
      ;; Special case: a positive exact number of arguments.
      (when (and (< 0 min) (eql min max))
        (return `(call-internal |checkArgs| (nargs) ,min)))
      ;; General case:
      `(progn
         ,(when (< 0 min)     `(call-internal |checkArgsAtLeast| (nargs) ,min))
         ,(when (numberp max) `(call-internal |checkArgsAtMost|  (nargs) ,max))))))

(defun compile-lambda-optional (ll)
  (let* ((optional-arguments (ll-optional-arguments-canonical ll))
         (n-required-arguments (length (ll-required-arguments ll)))
         (n-optional-arguments (length optional-arguments)))
    (when optional-arguments
      `(switch (nargs)
               ,@(let ((*target* (make-target)))
                      (dotimes (idx n-optional-arguments (target-statements))
                        (destructuring-bind (name &optional value present)
                            (nth idx optional-arguments)
                          (emit `(case ,(+ idx n-required-arguments)))
                          (convert value (translate-variable name))
                          (when present
                            (convert nil (translate-variable present))))))))))

(defun compile-lambda-rest (ll)
  (let ((n-required-arguments (length (ll-required-arguments ll)))
        (n-optional-arguments (length (ll-optional-arguments ll)))
        (rest-argument (ll-rest-argument ll)))
    (when rest-argument
      (let ((js!rest (translate-variable rest-argument)))
        `(progn
           (var (,js!rest ,(convert nil)))
           (var i)
           (for ((= i (- (nargs) 1))
                 (>= i ,(+ n-required-arguments n-optional-arguments))
                 (post-- i))
                (= ,js!rest (object "car" (arg i)
                                    "cdr" ,js!rest))))))))

(defun compile-lambda-parse-keywords (ll)
  (let ((n-required-arguments (length (ll-required-arguments ll)))
        (n-optional-arguments (length (ll-optional-arguments ll)))
        (keyword-arguments (ll-keyword-arguments-canonical ll)))
    `(progn
       ;; Declare variables
       ,@(let ((*target* (make-target)))
              (dolist (keyword-argument keyword-arguments (target-statements))
                (destructuring-bind ((keyword-name var) &optional initform svar)
                    keyword-argument
                  (declare (ignore keyword-name initform))
                  (emit `(var ,(translate-variable var)))
                  (when svar
                    (emit
                     `(var (,(translate-variable svar)
                             ,(convert nil))))))))

       ;; Parse keywords
       ,(flet ((parse-keyword (keyarg)
                              (destructuring-bind ((keyword-name var) &optional initform svar) keyarg
                                ;; ((keyword-name var) init-form svar)
                                `(progn
                                   (for ((= i ,(+ n-required-arguments n-optional-arguments))
                                         (< i (nargs))
                                         (+= i 2))
                                        ;; ....
                                        (if (=== (arg i) ,(convert keyword-name))
                                            (progn
                                              (= ,(translate-variable var) (arg (+ i 1)))
                                              ,(when svar `(= ,(translate-variable svar)
                                                              ,(convert t)))
                                              (break))))
                                   (if (== i (nargs))
                                       ,(convert-to-block initform (translate-variable var)))))))
              (when keyword-arguments
                `(progn
                   (var i)
                   ,@(mapcar #'parse-keyword keyword-arguments))))

       ;; Check for unknown keywords
       ,(when keyword-arguments
              `(progn
                 (var (start ,(+ n-required-arguments n-optional-arguments)))
                 (if (== (% (- (nargs) start) 2) 1)
                     (throw "Odd number of keyword arguments."))
                 (for ((= i start) (< i (nargs)) (+= i 2))
                      (if (and ,@(mapcar (lambda (keyword-argument)
                                           (destructuring-bind ((keyword-name var) &optional initform svar)
                                               keyword-argument
                                             (declare (ignore var initform svar))
                                             `(!== (arg i) ,(convert keyword-name))))
                                         keyword-arguments))
                          (throw (+ "Unknown keyword argument " (property (arg i) "name"))))))))))

(defun parse-lambda-list (ll)
  (values (ll-required-arguments ll)
          (ll-optional-arguments ll)
          (ll-keyword-arguments  ll)
          (ll-rest-argument      ll)))

;;; Process BODY for declarations and/or docstrings. Return as
;;; multiple values the BODY without docstrings or declarations, the
;;; list of declaration forms and the docstring.
(defun parse-body (body &key declarations docstring)
  (let ((value-declarations)
        (value-docstring))
    ;; Parse declarations
    (when declarations
      (do* ((rest body (cdr rest))
            (form (car rest) (car rest)))
           ((or (atom form) (not (eq (car form) 'declare)))
            (setf body rest))
        (push form value-declarations)))
    ;; Parse docstring
    (when (and docstring
               (stringp (car body))
               (not (null (cdr body))))
      (setq value-docstring (car body))
      (setq body (cdr body)))
    (values body value-declarations value-docstring)))

;;; Compile a lambda function with lambda list LL and body BODY. If
;;; NAME is given, it should be a constant string and it will become
;;; the name of the function. If BLOCK is non-NIL, a named block is
;;; created around the body. NOTE: No block (even anonymous) is
;;; created if BLOCk is NIL.
(defun compile-lambda (ll body &key name block)
  (multiple-value-bind (required-arguments
                        optional-arguments
                        keyword-arguments
                        rest-argument)
      (parse-lambda-list ll)
    (multiple-value-bind (body decls documentation)
        (parse-body body :declarations t :docstring t)
      (declare (ignore decls))
      (let ((n-required-arguments (length required-arguments))
            (n-optional-arguments (length optional-arguments))
            (*environment* (extend-local-env
                            (append (ensure-list rest-argument)
                                    required-arguments
                                    optional-arguments
                                    keyword-arguments
                                    (ll-svars ll)))))

        (let* ((args (mapcar #'translate-variable (append required-arguments optional-arguments)))
               (func
                `(function (|values| ,@args)
                           ;; Check number of arguments
                           ,(lambda-check-argument-count n-required-arguments
                                                         n-optional-arguments
                                                         (or rest-argument keyword-arguments))
                           ,(compile-lambda-optional ll)
                           ,(compile-lambda-rest ll)
                           ,(compile-lambda-parse-keywords ll)

                           ,(let ((*multiple-value-p* t))
                                 (if block
                                     (convert-block `((block ,block ,@body)) t)
                                     (convert-block body t))))))

          (let ((fnvar (emit func t)))
            (when name
              (emit `(= (get ,fnvar "fname") ,name)))
            (when documentation
              (emit `(= (get ,fnvar "docstring") ,documentation)))
            fnvar))))))



(defun setq-pair (var val)
  (unless (symbolp var)
    (error "~a is not a symbol" var))
  (let ((b (lookup-in-lexenv var *environment* 'variable)))
    (cond
      ((and b
            (eq (binding-type b) 'variable)
            (not (member 'special (binding-declarations b)))
            (not (member 'constant (binding-declarations b))))
       (convert val (binding-value b)))

      ((and b (eq (binding-type b) 'macro))
       (convert `(setf ,var ,val) *out*))
      (t
       (convert `(set ',var ,val) *out*)))))

(define-compilation setq (&rest pairs)
  (cond
    ((and pairs (null (cddr pairs)))
     (setq-pair (car pairs) (cadr pairs)))
    ((null pairs)
     (convert nil *out*))
    ((null (cdr pairs))
     (error "Odd pairs in SETQ"))
    (t
     (setq-pair (car pairs) (cadr pairs))
     (convert `(setq ,@(cddr pairs)) *out*))))


;;; Compilation of literals an object dumping

;;; BOOTSTRAP MAGIC: We record the macro definitions as lists during
;;; the bootstrap. Once everything is compiled, we want to dump the
;;; whole global environment to the output file to reproduce it in the
;;; run-time. However, the environment must contain expander functions
;;; rather than lists. We do not know how to dump function objects
;;; itself, so we mark the list definitions with this object and the
;;; compiler will be called when this object has to be dumped.
;;; Backquote/unquote does a similar magic, but this use is exclusive.
;;;
;;; Indeed, perhaps to compile the object other macros need to be
;;; evaluated. For this reason we define a valid macro-function for
;;; this symbol.
(defvar *magic-unquote-marker* (gensym "MAGIC-UNQUOTE"))

#-jscl
(setf (macro-function *magic-unquote-marker*)
      (lambda (form &optional environment)
        (declare (ignore environment))
        (second form)))

(defvar *literal-table*)
(defvar *literal-counter*)

(defun genlit ()
  (incf *literal-counter*)
  (make-symbol (concat "l" (integer-to-string *literal-counter*))))

(defun dump-symbol (symbol)
  (let ((package (symbol-package symbol)))
    (cond
      ;; Uninterned symbol
      ((null package)
       `(new (call-internal |Symbol| ,(symbol-name symbol))))
      ;; Special case for bootstrap. For now, we just load all the
      ;; code with JSCL as the current package. We will compile the
      ;; JSCL package as CL in the target.
      #-jscl
      ((or (eq package (find-package "JSCL"))
           (eq package (find-package "CL")))
       `(call-internal |intern| ,(symbol-name symbol)))
      ;; Interned symbol
      (t
       `(call-internal |intern| ,(symbol-name symbol) ,(package-name package))))))

(defun dump-cons (cons)
  (let ((head (butlast cons))
        (tail (last cons)))
    `(call-internal |QIList|
                    ,@(mapcar (lambda (x) (literal x t)) head)
                    ,(literal (car tail) t)
                    ,(literal (cdr tail) t))))

(defun dump-array (array)
  (let ((elements (vector-to-list array)))
    (list-to-vector (mapcar #'literal elements))))

(defun dump-string (string)
  `(call-internal |make_lisp_string| ,string))

(defun literal (sexp &optional recursive)
  (cond
    ((integerp sexp) sexp)
    ((floatp sexp) sexp)
    ((characterp sexp) (string sexp))
    (t
     (or (cdr (assoc sexp *literal-table* :test #'eql))
         (let ((dumped (typecase sexp
                         (symbol (dump-symbol sexp))
                         (string (dump-string sexp))
                         (cons
                          ;; BOOTSTRAP MAGIC: See the root file
                          ;; jscl.lisp and the function
                          ;; `dump-global-environment' for further
                          ;; information.
                          (if (eq (car sexp) *magic-unquote-marker*)
                              (let ((*target* *toplevel-compilations*))
                                (convert (second sexp) t))
                              (dump-cons sexp)))
                         (array (dump-array sexp)))))
           (if (and recursive (not (symbolp sexp)))
               dumped
               (let ((jsvar (genlit)))
                 (push (cons sexp jsvar) *literal-table*)

                 (emit `(var (,jsvar ,dumped)) nil *toplevel-compilations*)
                 (when (keywordp sexp)
                   (emit `(= (get ,jsvar "value") ,jsvar) nil *toplevel-compilations*))

                 jsvar)))))))


(define-compilation quote (sexp)
  (literal sexp))

(define-compilation %while (pred &rest body)
  (let* ((v (gvarname))
         (condition
          `(selfcall
            (var ,v)
            ,(convert-to-block pred v)
            (return ,v))))

    (emit `(while (!== ,condition  ,(convert nil))
             ,(convert-to-block `(progn ,@body))))

    (convert nil *out*)))

(define-compilation function (x)
  (cond
    ((and (listp x) (eq (car x) 'lambda))
     (compile-lambda (cadr x) (cddr x)))
    ((and (listp x) (eq (car x) 'named-lambda))
     (destructuring-bind (name ll &rest body) (cdr x)
       (compile-lambda ll body
                       :name (symbol-name name)
                       :block name)))
    ((symbolp x)
     (let ((b (lookup-in-lexenv x *environment* 'function)))
       (if b
           (binding-value b)
           (convert `(symbol-function ',x)))))))

(defun make-function-binding (fname)
  (make-binding :name fname :type 'function :value (gvarname fname)))

(defun compile-function-definition (list)
  (compile-lambda (car list) (cdr list)))

(defun translate-function (name)
  (let ((b (lookup-in-lexenv name *environment* 'function)))
    (and b (binding-value b))))

(define-compilation flet (definitions &rest body)
  (let* ((fnames (mapcar #'car definitions))
         (cfuncs (mapcar (lambda (def)
                           (compile-lambda (cadr def)
                                           `((block ,(car def)
                                               ,@(cddr def)))))
                         definitions))
         (*environment*
          (extend-lexenv (mapcar #'make-function-binding fnames)
                         *environment*
                         'function)))
    (emit `(call (function ,(mapcar #'translate-function fnames)
                           ,(convert-block body t))
                 ,@cfuncs)
          *out*)))



(define-compilation labels (definitions &rest body)
  (let* ((fnames (mapcar #'car definitions))
         (*environment*
          (extend-lexenv (mapcar #'make-function-binding fnames)
                         *environment*
                         'function)))

    (let-target (target)
        (progn
          ;; Function definitions
          (dolist (definition definitions)
            (destructuring-bind (name lambda-list &rest body) definition
              (emit `(var (,(translate-function name)
                            ,(compile-lambda lambda-list
                                             `((block ,name ,@body))))))))
          ;; Body
          (emit (convert-block body t)))

      (emit `(selfcall
              ,@(target-statements target))
            *out*))))

;;; Was the compiler invoked from !compile-file?
(defvar *compiling-file* nil)

;;; NOTE: It is probably wrong in many cases but we will not use this
;;; heavily. Please, do not rely on wrong cases of this
;;; implementation.
(define-compilation eval-when (situations &rest body)
  ;; TODO: Error checking
  (cond
    ;; Toplevel form compiled by !compile-file.
    ((and *compiling-file* (zerop *convert-level*))
     ;; If the situation `compile-toplevel' is given. The form is
     ;; evaluated at compilation-time.
     (when (find :compile-toplevel situations)
       (eval (cons 'progn body)))
     ;; `load-toplevel' is given, then just compile the subforms as usual.
     (when (find :load-toplevel situations)
       (convert-toplevel `(progn ,@body) *multiple-value-p*))
     nil)
    
    ((find :execute situations)
     (convert `(progn ,@body) *out* *multiple-value-p*))
    (t
     (convert nil *out*))))

(define-compilation progn (&rest body)
  (dolist (expr (butlast body))
    (convert expr nil))
  (convert (car (last body)) *out* *multiple-value-p*))

(define-compilation macrolet (definitions &rest body)
  (let ((*environment* (copy-lexenv *environment*)))
    (dolist (def definitions)
      (destructuring-bind (name lambda-list &body body) def
        (let ((binding (make-binding :name name :type 'macro :value
                                     (let ((g!form (gensym)))
                                       `(lambda (,g!form)
                                          (destructuring-bind ,lambda-list ,g!form
                                            ,@body))))))
          (push-to-lexenv binding  *environment* 'function))))

    (convert `(progn ,@body) *out* *multiple-value-p*)))


(defun special-variable-p (x)
  (and (claimp x 'variable 'special) t))


(defun normalize-bindings (arg)
  (destructuring-bind (name &optional value)
      (ensure-list arg)
    (list name value)))


;;; Given a let-like description of bindings, return:
;;;
;;; 1. A list of lexical
;;; 2. A list of values to bind to the lexical variables
;;; 3. A alist of (special-variable . lexical-variable) to bind.
;;;
(defun process-bindings (bindings)
  (let ((bindings (mapcar #'normalize-bindings bindings))
        (special-bindings nil))
    (values
     ;; Lexical Variables
     (mapcar (lambda (var)
               (if (special-variable-p var)
                   (let ((lexvar (gensym)))
                     (push (cons var lexvar) special-bindings)
                     lexvar)
                   var))
             (mapcar #'car bindings))
     ;; Values
     (mapcar #'cadr bindings)
     ;; Binding special variables to lexical variables
     special-bindings)))


;;; Wrap CODE to restore the symbol values of the dynamic
;;; bindings. BINDINGS is a list of pairs of the form
;;; (SYMBOL . PLACE), where PLACE is a Javascript variable
;;; name to bind the symbol to.
(defun let-bind-dynamic-vars (special-bindings body)
  (if (null special-bindings)
      (convert-block body t t)
      (let ((special-variables (mapcar #'car special-bindings))
            (lexical-variables (mapcar #'cdr special-bindings)))
        `(return
           (call-internal
            |withDynamicBindings|
            ,(list-to-vector (mapcar #'literal special-variables))
            (function ()
                      ;; Set the value for the new bindings
                      ,@(mapcar (lambda (symbol jsvar)
                                  `(= (get ,symbol "value") ,jsvar))
                                (mapcar #'literal special-variables)
                                (mapcar #'translate-variable lexical-variables))

                      ,(convert-block body t t)))))))


(define-compilation let (bindings &rest body)
  (multiple-value-bind (lexical-variables values special-bindings)
      (process-bindings bindings)
    (let ((compiled-values (mapcar #'convert values))
          (*environment* (extend-local-env lexical-variables)))
      (emit `(call (function ,(mapcar #'translate-variable lexical-variables)
                             ,(let-bind-dynamic-vars special-bindings body))
                   ,@compiled-values)
            *out*))))




;; LET* compilation
;; 
;; (let* ((*var1* value1))
;;        (*var2* value2))
;;  ...)
;;
;;     var sbindings = [];
;;
;;     try {
;;       // compute value1
;;       // bind to var1
;;       // add var1 to sbindings
;;     
;;       // compute value2
;;       // bind to var2
;;       // add var2 to sbindings
;;
;;       // ...
;;
;;     } finally {
;;       // ...
;;       // restore bindings of sbindings
;;       // ...
;;     }
;; 
(define-compilation let* (bindings &rest body)
  (let ((bindings (mapcar #'ensure-list bindings))
        (*environment* (copy-lexenv *environment*))
        (sbindings (gvarname))
        (prelude-target (make-target))
        (postlude-target (make-target)))

    (let ((*target* prelude-target))
      (dolist (binding bindings)
        (destructuring-bind (variable &optional value) binding
          (cond
            ((special-variable-p variable)
             ;; VALUE is evaluated before the variable is bound.
             (let ((s (convert `',variable))
                   (v (convert value)))
               (emit `(method-call (get ,s "stack") "push"
                                   (get ,s "value")))
               (emit `(= (get ,s "value") ,v))
               ;; Arrange symbol to be unbound
               (emit `(method-call ,sbindings "push" ,s))))
            (t
             (let* ((jsvar (convert value))
                    (binding (make-binding :name variable :type 'variable :value jsvar)))
               (push-to-lexenv binding *environment* 'variable)))))))

    (let ((*target* postlude-target))
      (emit `(method-call ,sbindings "forEach"
                          (function (s)
                                    (= (get s "value")
                                       (method-call (get s "stack") "pop"))))))

    (let ((body
           `(progn
              ,@(target-statements prelude-target)
              ,(convert-block body t t))))
      
      (if (find-if #'special-variable-p bindings :key #'first)
          (emit
           `(selfcall
             (var (,sbindings #()))
             (try ,body)
             (finally ,@(target-statements postlude-target)))
           t)
          ;; If there is no special variables, we don't need try/catch
          (emit `(selfcall ,body) t)))))



(define-compilation block (name &rest body)
  ;; We use Javascript exceptions to implement non local control
  ;; transfer. Exceptions has dynamic scoping, so we use a uniquely
  ;; generated object to identify the block. The instance of a empty
  ;; array is used to distinguish between nested dynamic Javascript
  ;; exceptions. See https://github.com/davazp/jscl/issues/64 for
  ;; futher details.
  (let* ((idvar (gvarname name))
         (b (make-binding :name name :type 'block :value idvar)))
    (when *multiple-value-p*
      (push 'multiple-value (binding-declarations b)))
    (let* ((*environment* (extend-lexenv (list b) *environment* 'block))
           (cbody (convert-block body t)))
      (if (member 'used (binding-declarations b))
          (emit `(selfcall
                  (try
                   (var (,idvar #()))
                   ,cbody)
                  (catch (cf)
                    (if (and (instanceof cf (internal |BlockNLX|)) (== (get cf "id") ,idvar))
                        ,(if *multiple-value-p*
                             `(return (method-call |values| "apply" this
                                                   (call-internal |forcemv| (get cf "values"))))
                             `(return (get cf "values")))
                        (throw cf))))
                *out*)
          (emit `(selfcall ,cbody) *out*)))))

(define-compilation return-from (name &optional value)
  (let* ((b (lookup-in-lexenv name *environment* 'block))
         (multiple-value-p (member 'multiple-value (binding-declarations b))))
    (when (null b)
      (error "Return from unknown block `~S'." (symbol-name name)))
    (push 'used (binding-declarations b))
    ;; The binding value is the name of a variable, whose value is the
    ;; unique identifier of the block as exception. We can't use the
    ;; variable name itself, because it could not to be unique, so we
    ;; capture it in a closure.
    (let ((v (convert value t multiple-value-p)))
      (emit `(throw (new (call-internal |BlockNLX|
                                        ,(binding-value b)
                                        ,v
                                        ,(symbol-name name)))))
      nil)))

(define-compilation catch (id &rest body)
  (let ((values (if *multiple-value-p* '|values| '(internal |pv|))))
    (emit `(selfcall
            (var (id ,(convert id)))
            (try
             ,(convert-block body t))
            (catch (cf)
              (if (and (instanceof cf (internal |CatchNLX|)) (== (get cf "id") id))
                  (return (method-call ,values "apply" this
                                       (call-internal |forcemv| (get cf "values"))))
                  (throw cf))))
          *out*)))

(define-compilation throw (id value)
  (let ((out (gvarname)))
    (emit `(selfcall
            (var (|values| (internal |mv|)))
            (var ,out)
            ,(convert-to-block value out t)
            (throw (new (call-internal |CatchNLX| ,(convert id) ,out)))))))


(defun go-tag-p (x)
  (or (integerp x) (symbolp x)))

(defun declare-tagbody-tags (tbidx body)
  (let* ((go-tag-counter 0)
         (bindings
          (mapcar (lambda (label)
                    (let ((tagidx (incf go-tag-counter)))
                      (make-binding :name label :type 'gotag :value (list tbidx tagidx))))
                  (remove-if-not #'go-tag-p body))))
    (extend-lexenv bindings *environment* 'gotag)))

(define-compilation tagbody (&rest body)
  ;; Ignore the tagbody if it does not contain any go-tag. We do this
  ;; because 1) it is easy and 2) many built-in forms expand to a
  ;; implicit tagbody, so we save some space.
  (unless (some #'go-tag-p body)
    (return-from tagbody (convert `(progn ,@body nil))))
  ;; The translation assumes the first form in BODY is a label
  (unless (go-tag-p (car body))
    (push (gensym "START") body))
  ;; Tagbody compilation
  (let ((branch (gvarname 'branch))
        (tbidx (gvarname 'tbidx)))
    (let ((*environment* (declare-tagbody-tags tbidx body))
          initag)
      (let ((b (lookup-in-lexenv (first body) *environment* 'gotag)))
        (setq initag (second (binding-value b))))
      
      (emit `(selfcall
              ;; TAGBODY branch to take
              (var (,branch ,initag))
              (var (,tbidx #()))
              (label tbloop
                     (while true
                       (try
                        (switch ,branch
                                ,@(with-collect
                                   (collect `(case ,initag))
                                   (dolist (form (cdr body))
                                     (if (go-tag-p form)
                                         (let ((b (lookup-in-lexenv form *environment* 'gotag)))
                                           (collect `(case ,(second (binding-value b)))))
                                         (collect (convert-to-block form)))))
                                default
                                (break tbloop)))
                       (catch (jump)
                         (if (and (instanceof jump (internal |TagNLX|)) (== (get jump "id") ,tbidx))
                             (= ,branch (get jump "label"))
                             (throw jump)))))
              (return ,(convert nil)))
            *out*))))

(define-compilation go (label)
  (let ((b (lookup-in-lexenv label *environment* 'gotag)))
    (when (null b)
      (error "Unknown tag `~S'" label))
    (emit `(selfcall
            (throw (new (call-internal |TagNLX|
                                       ,(first (binding-value b))
                                       ,(second (binding-value b)))))))))

(define-compilation unwind-protect (form &rest clean-up)
  (let ((ret (gvarname)))
    (emit `(var (,ret ,(convert nil))))
    (emit `(try
            ,(convert-to-block form ret)))
    (emit `(finally
            ,(convert-block clean-up)))
    ret))

(define-compilation multiple-value-call (func-form &rest forms)
  (emit `(selfcall
          (var (func ,(convert func-form)))
          (var (args ,(vector (if *multiple-value-p* '|values| '(internal |pv|)))))
          (return
            (selfcall
             (var (|values| (internal |mv|)))
             (var vs)
             (progn
               ,@(with-collect
                  (dolist (form forms)
                    (collect (convert-to-block form 'vs t))
                    (collect `(if (and (=== (typeof vs) "object")
                                       (in "multiple-value" vs))
                                  (= args (method-call args "concat" vs))
                                  (method-call args "push" vs))))))
             (return (method-call func "apply" null args)))))
        *out*))

(define-compilation multiple-value-prog1 (first-form &rest forms)
  (convert first-form *out* *multiple-value-p*)
  (mapc (lambda (expr)
          (convert expr nil))
        forms))

(define-compilation backquote (form)
  (convert (bq-completely-process form) *out*))


;;; Primitives

(defvar *builtins*
  (make-hash-table))

(defmacro define-raw-builtin (name args &body body)
  ;; Creates a new primitive function `name' with parameters args and
  ;; @body. The body can access to the local environment through the
  ;; variable *ENVIRONMENT*.
  `(setf (gethash ',name *builtins*)
         (lambda ,args
           (block ,name ,@body))))


(defmacro define-builtin* (name args &body body)
  `(define-raw-builtin ,name ,args
     (let (,@(mapcar (lambda (arg)
                       `(,arg (convert ,arg)))
                     args))
       (progn ,@body)
       *out*)))

(defmacro define-builtin (name args &body body)
  `(define-builtin* ,name ,args
     (emit (progn ,@body) *out*)))


;;; VARIABLE-ARITY compiles variable arity operations. ARGS stands for
;;; a variable which holds a list of forms. It will compile them and
;;; store the result in some Javascript variables. BODY is evaluated
;;; with ARGS bound to the list of these variables to generate the
;;; code which performs the transformation on these variables.
(defun variable-arity-call (args function)
  (unless (consp args)
    (error "ARGS must be a non-empty list"))
  (let ((fargs '()))

    (dolist (x args)
      (let ((v (gvarname)))
        (push v fargs)
        (emit `(var (,v ,(convert x))))
        (emit `(if (!= (typeof ,v) "number")
                   (throw "Not a number!")))))
    
    (emit (funcall function (reverse fargs)) *out*)))


(defmacro variable-arity (args &body body)
  (unless (symbolp args)
    (error "`~S' is not a symbol." args))
  `(variable-arity-call ,args (lambda (,args) ,@body)))

(define-raw-builtin + (&rest numbers)
  (if (null numbers)
      0
      (variable-arity numbers `(+ ,@numbers))))

(define-raw-builtin - (x &rest others)
  (let ((args (cons x others)))
    (variable-arity args `(- ,@args))))

(define-raw-builtin * (&rest numbers)
  (if (null numbers)
      1
      (variable-arity numbers `(* ,@numbers))))

(define-raw-builtin / (x &rest others)
  (let ((args (cons x others)))
    (variable-arity args
      (if (null others)
          `(call-internal |handled_division| 1 ,(car args))
          (reduce (lambda (x y) `(call-internal |handled_division| ,x ,y))
                  args)))))

(define-builtin mod (x y)
  (emit `(if (== ,y 0) (throw "Division by zero")))
  `(% ,x ,y))


(defun comparison-conjuntion (vars op)
  (cond
    ((null (cdr vars))
     'true)
    ((null (cddr vars))
     `(,op ,(car vars) ,(cadr vars)))
    (t
     `(and (,op ,(car vars) ,(cadr vars))
           ,(comparison-conjuntion (cdr vars) op)))))


;;; Take a js-expr and return the same expr but returning T or NIL.
(defun convert-to-bool (expr &optional (out t))
  `(if ,expr
       ,(convert t out)
       ,(convert nil out)))

(defmacro define-builtin-comparison (op sym)
  `(define-raw-builtin ,op (x &rest args)
     (let ((args (cons x args)))
       (variable-arity args
         (convert-to-bool (comparison-conjuntion args ',sym))))))

(define-builtin-comparison > >)
(define-builtin-comparison < <)
(define-builtin-comparison >= >=)
(define-builtin-comparison <= <=)
(define-builtin-comparison = ==)
(define-builtin-comparison /= !=)

(define-builtin numberp (x)
  (convert-to-bool `(== (typeof ,x) "number")))

(define-builtin %floor (x)
  `(method-call |Math| "floor" ,x))

(define-builtin %ceiling (x)
  `(method-call |Math| "ceil" ,x))

(define-builtin expt (x y)
  `(method-call |Math| "pow" ,x ,y))

(define-builtin sqrt (x)
  `(method-call |Math| "sqrt" ,x))

(define-builtin float-to-string (x)
  `(call-internal |make_lisp_string| (method-call ,x |toString|)))

(define-builtin cons (x y)
  `(object "car" ,x "cdr" ,y))

(define-builtin consp (x)
  (convert-to-bool
   `(and (== (typeof ,x) "object")
         (in "car" ,x))))

(define-builtin* car (x)
  (emit `(if (=== ,x ,(convert nil))
             ,(and *out* `(= ,*out* ,(convert nil)))
             (if (and (== (typeof ,x) "object")
                      (in "car" ,x))
                 ,(and `(= ,*out* (get ,x "car")))
                 (throw "CAR called on non-list argument")))))

(define-builtin* cdr (x)
  (emit `(if (=== ,x ,(convert nil))
             ,(and *out* `(= ,*out* ,(convert nil)))
             (if (and (== (typeof ,x) "object")
                      (in "cdr" ,x))
                 ,(and *out* `(= ,*out* (get ,x "cdr")))
                 (throw "CDR called on non-list argument")))))

(define-builtin rplaca (x new)
  (emit `(= (get ,x "car") ,new))
  x)

(define-builtin rplacd (x new)
  (emit `(= (get ,x "cdr") ,new))
  x)

(define-builtin symbolp (x)
  (convert-to-bool `(instanceof ,x (internal |Symbol|))))

(define-builtin make-symbol (name)
  `(new (call-internal |Symbol| (call-internal |lisp_to_js| ,name))))

(define-compilation symbol-name (x)
  (convert `(oget ,x "name")))

(define-builtin set (symbol value)
  `(= (get ,symbol "value") ,value))

(define-builtin fset (symbol value)
  `(= (get ,symbol "fvalue") ,value))

(define-builtin boundp (x)
  (convert-to-bool `(!== (get ,x "value") undefined)))

(define-builtin fboundp (x)
  (convert-to-bool `(!== (get ,x "fvalue") undefined)))

(define-builtin* symbol-value (x)
  (emit `(get ,x "value") *out*)
  (emit `(if (=== ,*out* undefined)
             (throw (+ "Variable `" (get ,x "name") "' is unbound.")))))

(define-builtin symbol-function (x)
  `(call-internal |symbolFunction| ,x))

(define-builtin lambda-code (x)
  `(call-internal |make_lisp_string| (method-call ,x "toString")))

(define-builtin eq (x y)
  (convert-to-bool `(=== ,x ,y)))

(define-builtin char-code (x)
  `(call-internal |char_to_codepoint| ,x))

(define-builtin code-char (x)
  `(call-internal |char_from_codepoint| ,x))

(define-builtin characterp (x)
  (convert-to-bool
   `(and (== (typeof ,x) "string")
         (or (== (get ,x "length") 1)
             (== (get ,x "length") 2)))))

(define-builtin char-upcase (x)
  `(call-internal |safe_char_upcase| ,x))

(define-builtin char-downcase (x)
  `(call-internal |safe_char_downcase| ,x))

(define-builtin stringp (x)
  (convert-to-bool
   `(and (and (=== (typeof ,x) "object")
              (in "length" ,x))
         (== (get ,x "stringp") 1))))

(define-raw-builtin funcall (func &rest args)
  ;; TODO: Use SYMBOL-FUNCTION and optimize so we don't lookup every time.
  (let ((f (convert func)))
    (emit `(call (if (=== (typeof ,f) "function")
                     ,f
                     (get ,f "fvalue"))
                 ,@(cons (if *multiple-value-p* '|values| '(internal |pv|))
                         (mapcar #'convert args)))
          *out*)))

(define-raw-builtin apply (func arg &rest args)
  (let ((args (cons arg args)))
    (let ((args (butlast args))
          (last (car (last args))))
      (emit `(selfcall
              (var (f ,(convert func)))
              (var (args ,(list-to-vector
                           (cons (if *multiple-value-p* '|values| '(internal |pv|))
                                 (mapcar #'convert args)))))
              (var (tail ,(convert last)))
              (while (!= tail ,(convert nil))
                (method-call args "push" (get tail "car"))
                (= tail (get tail "cdr")))
              (return (method-call (if (=== (typeof f) "function")
                                       f
                                       (get f "fvalue"))
                                   "apply"
                                   this
                                   args)))
            *out*))))

(define-builtin js-eval (string)
  (if *multiple-value-p*
      `(selfcall
        (var (v (call-internal |globalEval| (call-internal |xstring| ,string))))
        (return (method-call |values| "apply" this (call-internal |forcemv| v))))
      `(call-internal |globalEval| (call-internal |xstring| ,string))))

(define-builtin* %throw (string)
  (emit `(throw ,string)))

(define-builtin functionp (x)
  (convert-to-bool `(=== (typeof ,x) "function")))

(define-builtin /debug (x)
  `(method-call |console| "log" (call-internal |xstring| ,x)))

(define-builtin /log (x)
  `(method-call |console| "log" ,x))


;;; Storage vectors. They are used to implement arrays and (in the
;;; future) structures.

(define-builtin storage-vector-p (x)
  (convert-to-bool
   `(and (=== (typeof ,x) "object")
         (in "length" ,x))))

(define-builtin* make-storage-vector (n)
  (emit #() *out*)
  (emit `(= (get ,*out* "length") ,n)))

(define-builtin storage-vector-size (x)
  `(get ,x "length"))

(define-builtin resize-storage-vector (vector new-size)
  `(= (get ,vector "length") ,new-size))

(define-builtin* storage-vector-ref (vector n)
  (emit `(property ,vector ,n) *out*)
  (emit `(if (=== ,*out* undefined)
             (throw "Out of range."))))

(define-builtin storage-vector-set (vector n value)
  (emit `(if (or (< ,n 0) (>= ,n (get ,vector "length")))
             (throw "Out of range.")))
  `(= (property ,vector ,n) ,value))

(define-builtin* concatenate-storage-vector (sv1 sv2)
  (let ((r (emit `(method-call ,sv1 "concat" ,sv2) *out*)))
    (emit `(= (get ,r "type") (get ,sv1 "type")))
    (emit `(= (get ,r "stringp") (get ,sv1 "stringp")))))

(define-builtin get-internal-real-time ()
  `(method-call (new (call |Date|)) "getTime"))

(define-builtin values-array (array)
  (if *multiple-value-p*
      `(method-call |values| "apply" this ,array)
      `(method-call (internals |pv|) "apply" this ,array)))

(define-raw-builtin values (&rest args)
  (let ((call
         (if *multiple-value-p*
             `(call |values| ,@(mapcar #'convert args))
             `(call-internal |pv| ,@(mapcar #'convert args)))))
    (emit call *out*)))

;;; Javascript FFI

(define-builtin new ()
  '(object))

(define-raw-builtin oget* (object key &rest keys)
  (emit `(selfcall
          (progn
            (var (tmp (property ,(convert object) (call-internal |xstring| ,(convert key)))))
            ,@(mapcar (lambda (key)
                        `(progn
                           (if (=== tmp undefined) (return ,(convert nil)))
                           (= tmp (property tmp (call-internal |xstring| ,(convert key))))))
                      keys))
          (return (if (=== tmp undefined) ,(convert nil) tmp)))
        *out*))

(define-raw-builtin oset* (value object key &rest keys)
  (let ((keys (cons key keys)))
    (emit `(selfcall
            (progn
              (var (obj ,(convert object)))
              ,@(mapcar (lambda (key)
                          `(progn
                             (= obj (property obj (call-internal |xstring| ,(convert key))))
                             (if (=== obj undefined)
                                 (throw "Impossible to set object property."))))
                        (butlast keys))
              (var (tmp
                    (= (property obj (call-internal |xstring| ,(convert (car (last keys)))))
                       ,(convert value))))
              (return (if (=== tmp undefined)
                          ,(convert nil)
                          tmp))))
          *out*)))

(define-raw-builtin oget (object key &rest keys)
  (emit `(call-internal |js_to_lisp| ,(convert `(oget* ,object ,key ,@keys)))
        *out*))

(define-raw-builtin oset (value object key &rest keys)
  (convert `(oset* (lisp-to-js ,value) ,object ,key ,@keys)))

(define-builtin js-null-p (x)
  (convert-to-bool `(=== ,x null)))

(define-builtin objectp (x)
  (convert-to-bool `(=== (typeof ,x) "object")))

(define-builtin %%nlx-p (x)
  (convert-to-bool `(call-internal |isNLX| ,x)))

(define-builtin %%throw (x)
  `(selfcall (throw ,x)))

(define-builtin lisp-to-js (x) `(call-internal |lisp_to_js| ,x))
(define-builtin js-to-lisp (x) `(call-internal |js_to_lisp| ,x))


(define-builtin in (key object)
  (convert-to-bool `(in (call-internal |xstring| ,key) ,object)))

(define-builtin delete-property (key object)
  `(selfcall
    (delete (property ,object (call-internal |xstring| ,key)))))

(define-builtin map-for-in (function object)
  `(selfcall
    (var (f ,function)
         (g (if (=== (typeof f) "function") f (get f "fvalue")))
         (o ,object)
         key)
    (for-in (key o)
            (call g ,(if *multiple-value-p* '|values| '(internal |pv|))
		  (property o key)))
    (return ,(convert nil))))

(define-compilation %js-vref (var)
  (emit `(call-internal |js_to_lisp| ,(make-symbol var)) *out*))

(define-compilation %js-vset (var val)
  (let ((value (convert val)))
    (emit `(= ,(make-symbol var) (call-internal |lisp_to_js| ,value)) *out*)))

(define-setf-expander %js-vref (var)
  (let ((new-value (gensym)))
    (unless (stringp var)
      (error "`~S' is not a string." var))
    (values nil
            (list var)
            (list new-value)
            `(%js-vset ,var ,new-value)
            `(%js-vref ,var))))

(define-compilation %js-typeof (x)
  (emit `(call-internal |js_to_lisp| (typeof ,x)) *out*))



;; Catch any Javascript exception. Note that because all non-local
;; exit are based on try-catch-finally, it will also catch them. We
;; could provide a JS function to detect it, so the user could rethrow
;; the error.
;;
;; (%js-try
;;  (progn
;;    )
;;  (catch (err)
;;    )
;;  (finally
;;   ))
;;
(define-compilation %js-try (form &optional catch-form finally-form)
  (let ((catch-compilation
         (and catch-form
              (destructuring-bind (catch (var) &body body) catch-form
                (unless (eq catch 'catch)
                  (error "Bad CATCH clausule `~S'." catch-form))
                (let* ((*environment* (extend-local-env (list var)))
                       (tvar (translate-variable var)))
                  `(catch (,tvar)
                     (= ,tvar (call-internal |js_to_lisp| ,tvar))
                     ,(convert-block body t))))))

        (finally-compilation
         (and finally-form
              (destructuring-bind (finally &body body) finally-form
                (unless (eq finally 'finally)
                  (error "Bad FINALLY clausule `~S'." finally-form))
                `(finally
                  ,(convert-block body))))))

    (emit `(selfcall
            (try ,(convert-block (list form) t))
            ,catch-compilation
            ,finally-compilation)
          *out*)))


(define-compilation symbol-macrolet (macrobindings &rest body)
  (let ((new (copy-lexenv *environment*)))
    (dolist (macrobinding macrobindings)
      (destructuring-bind (symbol expansion) macrobinding
        (let ((b (make-binding :name symbol :type 'macro :value expansion)))
          (push-to-lexenv b new 'variable))))
    (let ((*environment* new))
      (convert-block body nil t))))


#-jscl
(defvar *macroexpander-cache*
  (make-hash-table :test #'eq))

(defun !macro-function (symbol)
  (unless (symbolp symbol)
    (error "`~S' is not a symbol." symbol))
  (let ((b (lookup-in-lexenv symbol *environment* 'function)))
    (if (and b (eq (binding-type b) 'macro))
        (let ((expander (binding-value b)))
          (cond
            #-jscl
            ((gethash b *macroexpander-cache*)
             (setq expander (gethash b *macroexpander-cache*)))
            ((listp expander)
             (let ((compiled (eval expander)))
               ;; The list representation are useful while
               ;; bootstrapping, as we can dump the definition of the
               ;; macros easily, but they are slow because we have to
               ;; evaluate them and compile them now and again. So, let
               ;; us replace the list representation version of the
               ;; function with the compiled one.
               ;;
               #+jscl (setf (binding-value b) compiled)
               #-jscl (setf (gethash b *macroexpander-cache*) compiled)
               (setq expander compiled))))
          expander)
        nil)))

(defun !macroexpand-1 (form)
  (cond
    ((symbolp form)
     (let ((b (lookup-in-lexenv form *environment* 'variable)))
       (if (and b (eq (binding-type b) 'macro))
           (values (binding-value b) t)
           (values form nil))))
    ((and (consp form) (symbolp (car form)))
     (let ((macrofun (!macro-function (car form))))
       (if macrofun
           (values (funcall macrofun (cdr form)) t)
           (values form nil))))
    (t
     (values form nil))))


(defun !macroexpand (sexp)
  (multiple-value-bind (sexp expandedp) (!macroexpand-1 sexp)
    (if expandedp (!macroexpand sexp) sexp)))


(defun compile-funcall (function args)
  (let* ((arglist (cons (if *multiple-value-p* '|values| '(internal |pv|))
                        (mapcar #'convert args))))
    (unless (or (symbolp function)
                (and (consp function)
                     (member (car function) '(lambda oget))))
      (error "Bad function designator `~S'" function))
    (cond
      ((translate-function function)
       (emit `(call ,(translate-function function) ,@arglist) *out*))
      ((symbolp function)
       (fn-info function :called t)
       ;; This code will work even if the symbol-function is unbound,
       ;; as it is represented by a function that throws the expected
       ;; error.
       (let ((fn (convert `',function)))
         (emit `(method-call ,fn "fvalue" ,@arglist) *out*)))

      ((and (consp function) (eq (car function) 'lambda))
       (let ((fn (convert `(function ,function))))
         (emit `(call ,fn ,@arglist) *out*)))
      
      ((and (consp function) (eq (car function) 'oget))
       (emit `(call-internal |js_to_lisp|
                             (call ,(reduce (lambda (obj p)
                                              `(property ,obj (call-internal |xstring| ,p)))
                                      
                                            (mapcar #'convert (cdr function)))
                                   ,@(mapcar (lambda (s)
                                               `(call-internal |lisp_to_js| ,(convert s)))
                                             args)))
             *out*))
      (t
       (error "Bad function descriptor")))))

(defun convert-block (sexps &optional return-last-p decls-allowed-p)
  (multiple-value-bind (sexps decls)
      (parse-body sexps :declarations decls-allowed-p)
    (declare (ignore decls))
    (let (output)
      (let-target (target)
          (progn
            (mapc (lambda (expr) (convert expr nil))
                  (butlast sexps))
            (setq output (convert (first (last sexps)) t *multiple-value-p*))
            (when return-last-p
              (emit `(return ,output))))
        (values `(progn
                   ,@(target-statements target))
                output)))))


(defun convert-1 (sexp)
  (cond
    ((symbolp sexp)
     (let ((b (lookup-in-lexenv sexp *environment* 'variable)))
       (cond
         ((and b (not (member 'special (binding-declarations b))))
          (binding-value b))
         ((or (keywordp sexp)
              (and b (member 'constant (binding-declarations b))))
          (emit `(get ,(convert `',sexp) "value") *out*))
         (t
          (convert `(symbol-value ',sexp) *out*)))))
    ((or (integerp sexp) (floatp sexp) (characterp sexp) (stringp sexp) (arrayp sexp))
     (literal sexp))
    ((listp sexp)
     (let ((name (car sexp))
           (args (cdr sexp)))
       (cond
         ;; Special forms
         ((gethash name *compilations*)
          (let ((comp (gethash name *compilations*)))
            (apply comp args)))
         ;; Built-in functions
         ((and (gethash name *builtins*)
               (not (claimp name 'function 'notinline)))
          (apply (gethash name *builtins*) args))
         (t
          (compile-funcall name args)))))
    (t
     (error "How should I compile `~S'?" sexp))))


;;; Compile SEXP into the currently target (*TARGET*).
;;;
;;; Arguments:
;;;
;;;    - OUT: Variable in which the result of SEXP will be placed.
;;;
;;;       o T means that a new variable will be declared and the value
;;;         f SEXP will be assigned to it. This is the default value.
;;;
;;;       o NIL means that the value should be discarded.
;;;
;;;       o A symbol as returned by gvarname will assignt he result of
;;;         SEXP to that variable, which should already exist in the
;;;         output code.
;;;
;;;    - MULTIPLE-VALUE-P: T if the form being compiled is in a
;;;      position where multiple values could be consumed. NIL otherwise.
;;;
;;; Return the output variable or NIL if the value should be
;;; discarded.
;;;
(defun convert (sexp &optional (out t) multiple-value-p)
  (let ((sexp (!macroexpand sexp)))
    ;; The expression has been macroexpanded. Now compile it!
    (let ((*multiple-value-p* multiple-value-p)
          (*convert-level* (1+ *convert-level*))
          (*out* (if (eq out t)
                     (let ((v (gvarname)))
                       (emit `(var ,v))
                       v)
                     out)))
      (let ((res (convert-1 sexp)))
        (when (and res
                   *out*
                   (not (eq res *out*)))
          (emit res *out*))
        *out*))))


;;; Like `convert', but it compiles into a block of statements insted.
(defun convert-to-block (sexp &optional out multiple-value-p)
  (let-target (target)
      (convert sexp out multiple-value-p)
    `(progn ,@(target-statements target))))


(defvar *compile-print-toplevels* nil)

(defun truncate-string (string &optional (width 60))
  (let ((n (or (position #\newline string)
               (min width (length string)))))
    (subseq string 0 n)))

(defun convert-toplevel (sexp &optional multiple-value-p return-p)
  ;; Process as toplevel
  (let ((sexp (!macroexpand sexp))
        (*convert-level* -1))
    (cond
      ;; Non-empty toplevel progn
      ((and (consp sexp)
            (eq (car sexp) 'progn)
            (cdr sexp))

       ;; Discard all except the last value
       (mapc (lambda (s) (convert-toplevel s nil))
             (butlast (cdr sexp)))
       
       (convert-toplevel (first (last (cdr sexp))) multiple-value-p return-p))
      
      (t
       (when *compile-print-toplevels*
         (let ((form-string (prin1-to-string sexp)))
           (format t "Compiling ~a...~%" (truncate-string form-string))))

       (let ((code (convert sexp (if return-p t nil) multiple-value-p)))
         (when return-p
           (emit `(return ,code))))))))


(defun process-toplevel (sexp &optional multiple-value-p return-p)
  (let* ((*toplevel-compilations* (make-target))
         (*target* *toplevel-compilations*))
    (let ((code (convert-toplevel sexp multiple-value-p return-p)))
      `(progn
         ,@(target-statements)
         ,code))))


(defun compile-toplevel (sexp &optional multiple-value-p return-p)
  (with-output-to-string (*js-output*)
    (js (process-toplevel sexp multiple-value-p return-p))))


(defmacro with-compilation-environment (&body body)
  `(let ((*literal-table* nil)
         (*variable-counter* 0)
         (*gensym-counter* 0)
         (*literal-counter* 0))
     ,@body))
