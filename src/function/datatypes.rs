use constant::{Constant, Matrix};
use std::cell::{RefCell, Ref, RefMut};
use std::collections::{HashMap, HashSet};
use std::rc::Rc;
use std::ops::Deref;

type Shared<T> = Rc<RefCell<T>>;

pub fn get_shared<T>(s: &Shared<T>) -> Ref<T> { s.borrow() }

pub mod shared {
    use std::{rc, cell};
    use function::datatypes::Shared;

    pub fn new<T>(value: T) -> Shared<T> {
        rc::Rc::new(cell::RefCell::new(value))
    }
}

#[derive(Debug)]
pub struct Input {
    pub dims: Vec<i32>, 
    pub name: String,
}

#[derive(Debug)]
pub struct Param {
    pub name: String,
}

#[derive(Debug)]
pub enum Expr {
    Constant(Constant),
    Input(Input),
    Param(Param),
    Neg(Function),
    Abs(Function),
    Signum(Function),
    Sigmoid(Function),
    Add(Function, Function),
    Sub(Function, Function),
    Mul(Function, Function),
    Dot(Function, Function),
}

#[derive(Debug, Clone)]
pub struct Function {
    pub value: Shared<Option<Constant>>,
    pub params: HashSet<String>,
    pub body: Rc<Expr>,
    pub placeholders: Vec<Constant>,
}

impl Function {
    pub fn set_value(&self, value: Constant) {
        *(&self.value).borrow_mut() = Some(value);
    }

    pub fn get_value(&self) -> Ref<Option<Constant>> {
        self.value.borrow()
    }

   pub fn mutate_value(&self, f: &Fn(&mut Constant)) {
        match *self.value.borrow_mut() {
            Some(ref mut value) => f(value),
            None => panic!("Tried to mutate value that hasn't been assigned yet."),
        }
    }

    pub fn unwrap_value<'a>(&'a self) -> Ref<Constant> {
        Ref::map(self.value.borrow(), |t| match t.as_ref() {
            Some(x) => x,
            None => panic!("{:?} failed", self),
        })
    }
}
